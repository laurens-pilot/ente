package io.ente.background

import android.app.Activity
import android.app.Application
import android.os.Looper
import androidx.work.Configuration
import androidx.work.Data
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.view.FlutterCallbackInformation
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentMatchers.*
import org.mockito.Mockito.*
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class BackgroundRuntimeTest {
    private val app: Application
        get() = RuntimeEnvironment.getApplication()

    private val startups = ArrayDeque<Runnable>()
    private val engines = ArrayList<Pair<FlutterEngine, Messenger>>()
    private val main
        get() = shadowOf(Looper.getMainLooper())

    private fun policy(budget: Long? = null, grace: Long? = null) =
        TaskConfiguration(
            "test.refresh",
            "refresh",
            900_000,
            86_400_000,
            null,
            false,
            false,
            false,
            budget,
            grace,
            1,
        )

    private fun configure(policy: TaskConfiguration, enabled: Boolean = true) {
        val data = org.json.JSONObject(policy.encode())
        val result = Reply()
        BackgroundRuntime.configure(
            mapOf(
                "enabled" to enabled,
                "callbackHandle" to 1L,
                "tasks" to
                    listOf(
                        data.keys().asSequence().associateWith { key ->
                            data.get(key).takeUnless { it === org.json.JSONObject.NULL }
                        }
                    ),
            ),
            result,
        )
        val deadline = System.nanoTime() + 10_000_000_000L
        while (!result.done && System.nanoTime() < deadline) {
            main.idle()
            Thread.sleep(5)
        }
        assertTrue("Configuration did not finish", result.done)
        assertNull(result.error)
    }

    private fun worker(policy: TaskConfiguration): BackgroundWorker =
        TestListenableWorkerBuilder<BackgroundWorker>(app)
            .setInputData(Data.Builder().putString("task", policy.encode()).build())
            .build()

    private fun bootstrap(): Messenger {
        startups.removeFirst().run()
        return engines.last().second
    }

    private fun complete(messenger: Messenger, ready: Map<*, *>, outcome: String = "completed") {
        messenger.call("complete", mapOf("invocation" to ready["invocation"], "outcome" to outcome))
    }

    @Test
    fun lifecycleThroughNativeWorkerAndDartChannel() {
        WorkManagerTestInitHelper.initializeTestWorkManager(app, Configuration.Builder().build())
        BackgroundRuntime.install(app) { true }
        val loader = mock(FlutterLoader::class.java)
        doAnswer { invocation ->
                startups.add(invocation.getArgument(3))
                null
            }
            .`when`(loader)
            .ensureInitializationCompleteAsync(any(), isNull(), any(), any())
        `when`(loader.findAppBundlePath()).thenReturn("flutter_assets")
        FlutterInjector.setInstance(FlutterInjector.Builder().setFlutterLoader(loader).build())
        BackgroundRuntime.findCallback = { mock(FlutterCallbackInformation::class.java) }
        BackgroundRuntime.createEngine = {
            val engine = mock(FlutterEngine::class.java)
            val executor = mock(DartExecutor::class.java)
            val messenger = Messenger()
            `when`(engine.dartExecutor).thenReturn(executor)
            `when`(executor.binaryMessenger).thenReturn(messenger)
            engines.add(engine to messenger)
            engine
        }

        val cooperative = policy()
        configure(cooperative)
        val activity = Robolectric.buildActivity(Activity::class.java).create().start().resume()
        assertEquals(ListenableWorker.Result.success(), worker(cooperative).startWork().get())
        assertTrue(startups.isEmpty())
        assertTrue(engines.isEmpty())
        activity.pause().stop().destroy()

        val first = worker(cooperative).startWork()
        assertFalse(first.isDone)
        assertEquals(ListenableWorker.Result.success(), worker(cooperative).startWork().get())
        assertEquals(1, startups.size)
        val firstChannel = bootstrap()
        val firstReady = firstChannel.call("ready") as Map<*, *>
        assertNull(firstReady["stopReason"])
        doAnswer {
                assertEquals(
                    ListenableWorker.Result.success(),
                    worker(cooperative).startWork().get(),
                )
                null
            }
            .`when`(engines[0].first)
            .destroy()
        val stop = Reply()
        BackgroundRuntime.requestStop(stop)
        assertFalse(stop.done)
        assertEquals("requested", (firstChannel.sent.single().arguments as Map<*, *>)["reason"])
        assertEquals(ListenableWorker.Result.success(), worker(cooperative).startWork().get())
        assertFalse(stop.done)
        complete(firstChannel, firstReady)
        assertTrue(stop.done)
        assertEquals(ListenableWorker.Result.success(), first.get())
        verify(engines[0].first).destroy()
        val noRun = Reply()
        BackgroundRuntime.requestStop(noRun)
        assertTrue(noRun.done)
        val schedule = Reply()
        BackgroundRuntime.scheduledTasks(schedule)
        val scheduleDeadline = System.nanoTime() + 10_000_000_000L
        while (!schedule.done && System.nanoTime() < scheduleDeadline) {
            main.idle()
            Thread.sleep(5)
        }
        assertEquals(mapOf("test.refresh" to true), schedule.value)

        val budgetPolicy = policy(budget = 100)
        configure(budgetPolicy)
        val budgetRun = worker(budgetPolicy).startWork()
        main.idleFor(Duration.ofMillis(150))
        val budgetChannel = bootstrap()
        val budgetReady = budgetChannel.call("ready") as Map<*, *>
        assertEquals("budget", budgetReady["stopReason"])
        assertTrue((budgetReady["elapsedMs"] as Long) >= 150)
        assertFalse(budgetRun.isDone)
        main.idleFor(Duration.ofSeconds(1))
        verify(engines.last().first, never()).destroy()
        complete(budgetChannel, budgetReady)
        assertTrue(budgetRun.isDone)

        configure(cooperative)
        val stoppingDuringStartup = worker(cooperative).startWork()
        val foreground = Robolectric.buildActivity(Activity::class.java).create().start().resume()
        val stoppedChannel = bootstrap()
        val stoppedReady = stoppedChannel.call("ready") as Map<*, *>
        assertEquals("foreground", stoppedReady["stopReason"])
        foreground.pause().stop().destroy()
        main.idleFor(Duration.ofSeconds(2))
        assertFalse(stoppingDuringStartup.isDone)
        complete(stoppedChannel, stoppedReady)
        assertTrue(stoppingDuringStartup.isDone)

        val original = policy(grace = 500)
        configure(original)
        val forced = worker(original).startWork()
        val forcedChannel = bootstrap()
        val forcedReady = forcedChannel.call("ready") as Map<*, *>
        val foregroundAgain =
            Robolectric.buildActivity(Activity::class.java).create().start().resume()
        configure(policy(grace = 1))
        main.idleFor(Duration.ofMillis(200))
        assertFalse(forced.isDone)
        foregroundAgain.pause().stop().start().resume()
        main.idleFor(Duration.ofMillis(300))
        assertEquals(ListenableWorker.Result.failure(), forced.get())
        verify(engines.last().first).destroy()
        foregroundAgain.pause().stop().destroy()

        val updated = worker(policy(grace = 1)).startWork()
        val updatedChannel = bootstrap()
        val updatedReady = updatedChannel.call("ready") as Map<*, *>
        assertNotEquals(forcedReady["invocation"], updatedReady["invocation"])
        assertNull(
            forcedChannel.call(
                "complete",
                mapOf("invocation" to forcedReady["invocation"], "outcome" to "completed"),
            )
        )
        assertFalse(updated.isDone)
        BackgroundRuntime.foreground()
        main.idleFor(Duration.ofMillis(1))
        assertEquals(ListenableWorker.Result.failure(), updated.get())
        val clearForeground =
            Robolectric.buildActivity(Activity::class.java).create().start().resume()
        clearForeground.pause().stop().destroy()

        configure(cooperative)
        val interruptedWorker = worker(cooperative)
        val interrupted = interruptedWorker.startWork()
        val staleStartup = startups.removeFirst()
        interruptedWorker.onStopped()
        main.idle()
        assertTrue(interrupted.isDone)
        val replacement = worker(cooperative).startWork()
        val count = engines.size
        staleStartup.run()
        assertEquals(count, engines.size)
        val replacementChannel = bootstrap()
        val replacementReady = replacementChannel.call("ready") as Map<*, *>
        complete(replacementChannel, replacementReady)
        assertTrue(replacement.isDone)

        val immediatePolicy = policy(budget = 0, grace = 0)
        configure(immediatePolicy)
        val immediate = worker(immediatePolicy).startWork()
        main.idle()
        val immediateChannel = bootstrap()
        val immediateReady = immediateChannel.call("ready") as Map<*, *>
        assertEquals("budget", immediateReady["stopReason"])
        assertFalse(immediate.isDone)
        val immediateForeground =
            Robolectric.buildActivity(Activity::class.java).create().start().resume()
        main.idle()
        assertEquals(ListenableWorker.Result.failure(), immediate.get())
        immediateForeground.pause().stop().destroy()

        configure(cooperative)
        BackgroundRuntime.findCallback = { null }
        val failed = worker(cooperative).startWork()
        startups.removeFirst().run()
        assertEquals(ListenableWorker.Result.failure(), failed.get())
        BackgroundRuntime.findCallback = { mock(FlutterCallbackInformation::class.java) }
        val last = worker(cooperative).startWork()
        val lastChannel = bootstrap()
        val lastReady = lastChannel.call("ready") as Map<*, *>
        configure(cooperative, enabled = false)
        assertFalse(last.isDone)
        assertEquals("requested", (lastChannel.sent.single().arguments as Map<*, *>)["reason"])
        complete(lastChannel, lastReady)
        assertTrue(last.isDone)
    }

    private class Reply : MethodChannel.Result {
        var done = false
        var error: String? = null
        var value: Any? = null

        override fun success(result: Any?) {
            value = result
            done = true
        }

        override fun error(code: String, message: String?, details: Any?) {
            error = "$code: $message"
            done = true
        }

        override fun notImplemented() {
            error = "notImplemented"
            done = true
        }
    }

    private class Messenger : BinaryMessenger {
        private val codec = StandardMethodCodec.INSTANCE
        private var handler: BinaryMessenger.BinaryMessageHandler? = null
        val sent = ArrayList<MethodCall>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) {
            message?.flip()
            sent.add(codec.decodeMethodCall(requireNotNull(message)))
            callback?.reply(codec.encodeSuccessEnvelope(null).also { it.flip() })
        }

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {
            this.handler = handler
        }

        fun call(method: String, arguments: Any? = null): Any? {
            var reply: Any? = null
            handler?.onMessage(
                codec.encodeMethodCall(MethodCall(method, arguments)).also { it.flip() }
            ) { encoded ->
                encoded?.flip()
                reply = codec.decodeEnvelope(requireNotNull(encoded))
            }
            return reply
        }
    }
}
