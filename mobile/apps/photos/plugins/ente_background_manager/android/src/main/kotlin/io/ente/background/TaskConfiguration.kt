package io.ente.background

import org.json.JSONObject

internal data class TaskConfiguration(
    val identifier: String,
    val kind: String,
    val frequencyMs: Long,
    val initialDelayMs: Long,
    val flexMs: Long?,
    val requiresNetwork: Boolean,
    val requiresCharging: Boolean,
    val requiresDeviceIdle: Boolean,
    val runBudgetMs: Long?,
    val foregroundStopTimeoutMs: Long?,
    val callbackHandle: Long,
) {
    fun encode(): String =
        JSONObject(
                mapOf(
                    "identifier" to identifier,
                    "kind" to kind,
                    "frequencyMs" to frequencyMs,
                    "initialDelayMs" to initialDelayMs,
                    "flexMs" to flexMs,
                    "requiresNetwork" to requiresNetwork,
                    "requiresCharging" to requiresCharging,
                    "requiresDeviceIdle" to requiresDeviceIdle,
                    "runBudgetMs" to runBudgetMs,
                    "foregroundStopTimeoutMs" to foregroundStopTimeoutMs,
                    "callbackHandle" to callbackHandle,
                )
            )
            .toString()

    companion object {
        fun decode(
            json: JSONObject,
            callbackHandle: Long = json.getLong("callbackHandle"),
        ): TaskConfiguration {
            fun duration(key: String): Long? =
                if (json.isNull(key)) null else json.getLong(key).also { require(it >= 0) }

            val identifier = json.getString("identifier")
            val kind = json.getString("kind")
            val frequency = json.getLong("frequencyMs")
            val flex = duration("flexMs")
            require(identifier.isNotBlank())
            require(kind == "refresh" || kind == "processing")
            require(frequency >= 15 * 60 * 1000L)
            require(flex == null || flex in 5 * 60 * 1000L..frequency)
            require(callbackHandle != 0L)
            return TaskConfiguration(
                identifier,
                kind,
                frequency,
                duration("initialDelayMs") ?: 0,
                flex,
                json.optBoolean("requiresNetwork"),
                json.optBoolean("requiresCharging"),
                json.optBoolean("requiresDeviceIdle"),
                duration("runBudgetMs"),
                duration("foregroundStopTimeoutMs"),
                callbackHandle,
            )
        }
    }
}
