import "dart:async";
import "dart:math" as math;
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:intl/intl.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/models/file/file.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/local_authentication_service.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/effects.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/utils/thumbnail_util.dart";

class PhotosLanePage extends StatefulWidget {
  final List<EnteFile> files;
  final bool isGuestView;

  const PhotosLanePage({
    required this.files,
    this.isGuestView = false,
    super.key,
  });

  @override
  State<PhotosLanePage> createState() => _PhotosLanePageState();
}

class _PhotosLanePageState extends State<PhotosLanePage>
    with TickerProviderStateMixin {
  static const _frameInterval = Duration(seconds: 2);
  static const _cardTransitionDuration = Duration(milliseconds: 520);
  static const double _frameWidthFactor = 0.82;
  static const double _frameHeightFactor = 0.78;
  static const double _controlsDesiredGapToCard = 24;
  static const double _cardGapUpdateTolerance = 0.5;
  static const double _controlsHeightUpdateTolerance = 0.5;
  static const double _controlsHeightFallback = 140;
  // Wait for this many frames (or the available total) before auto-starting playback.
  static const int _initialFrameTarget = 120;
  static const int _frameBuildConcurrency = 6;
  static const double _appBarSideWidth = kToolbarHeight;
  static const bool _showPhotoDate = false;
  static const double _dragProgressPerCardWidth = 1.0;
  static const double _swipeVelocityThreshold = 900;

  final Logger _logger = Logger("PhotosLanePage");
  late final AnimationController _cardTransitionController;
  double _stackProgress = 0;
  late final ValueNotifier<double> _stackProgressNotifier;
  double _animationStartProgress = 0;
  int _targetIndex = 0;
  bool _isAnimatingCard = false;

  final List<_TimelineFrame> _frames = [];

  Timer? _playTimer;
  bool _isPlaying = false;
  bool _loggedPlaybackStart = false;
  bool _hasStartedPlayback = false;
  bool _allFramesLoaded = false;
  bool _timelineUnavailable = false;
  int _expectedFrameCount = 0;

  int _currentIndex = 0;
  double _cardGap = 0;
  double _controlsHeight = 0;
  final GlobalKey _controlsKey = GlobalKey();
  bool _isScrubbing = false;
  double _sliderValue = 0;
  double? _dragStartProgress;
  double _dragDistance = 0;
  late bool _isGuestView;
  bool get _featureEnabled => flagService.facesTimeline;

  @override
  void initState() {
    super.initState();
    _isGuestView = widget.isGuestView;
    _cardTransitionController = AnimationController(
      vsync: this,
      duration: _cardTransitionDuration,
    )
      ..addListener(_onCardAnimationTick)
      ..addStatusListener(_onCardAnimationStatusChanged);
    _stackProgressNotifier = ValueNotifier<double>(_stackProgress);
    if (_featureEnabled) {
      unawaited(_loadFrames());
    } else {
      _timelineUnavailable = true;
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _cardTransitionController
      ..removeListener(_onCardAnimationTick)
      ..removeStatusListener(_onCardAnimationStatusChanged)
      ..dispose();
    _stackProgressNotifier.dispose();
    super.dispose();
  }

  void _updateStackProgress(double value) {
    _stackProgress = value;
    const double epsilon = 1e-6;
    if ((_stackProgressNotifier.value - value).abs() <= epsilon) {
      return;
    }
    _stackProgressNotifier.value = value;
  }

  Future<void> _loadFrames() async {
    _playTimer?.cancel();
    if (mounted) {
      setState(() {
        _isPlaying = false;
      });
    }
    try {
      final files = widget.files;
      _expectedFrameCount = files.length;
      if (_expectedFrameCount == 0) {
        setState(() {
          _timelineUnavailable = true;
          _allFramesLoaded = true;
          _frames.clear();
          _hasStartedPlayback = false;
          _loggedPlaybackStart = false;
        });
        return;
      }

      setState(() {
        _timelineUnavailable = false;
        _allFramesLoaded = false;
        _frames.clear();
        _hasStartedPlayback = false;
        _loggedPlaybackStart = false;
        _animationStartProgress = 0;
        _targetIndex = 0;
        _isAnimatingCard = false;
        _currentIndex = 0;
        _sliderValue = 0;
      });
      _updateStackProgress(0);
      _cardTransitionController
        ..stop()
        ..value = 0;

      int loadedCount = 0;
      await _buildFramesInParallel(
        files: files,
        onFrameReady: (builtFrame) {
          if (!mounted) {
            return;
          }
          loadedCount += 1;
          _handleFrameLoaded(builtFrame, loadedCount);
        },
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _allFramesLoaded = true;
      });
    } catch (error, stackTrace) {
      _logger.severe(
        "Photos lane failed to load",
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _timelineUnavailable = true;
        _allFramesLoaded = true;
        _frames.clear();
        _hasStartedPlayback = false;
        _loggedPlaybackStart = false;
      });
    }
  }

  int get _initialFrameThreshold {
    if (_expectedFrameCount <= 0) {
      return 1;
    }
    return math.max(1, math.min(_initialFrameTarget, _expectedFrameCount));
  }

  void _handleFrameLoaded(_TimelineFrame frame, int loadedCount) {
    final bool isFirstFrame = _frames.isEmpty;
    setState(() {
      _frames.add(frame);
      if (isFirstFrame) {
        _currentIndex = 0;
        _sliderValue = 0;
        _animationStartProgress = 0;
        _targetIndex = 0;
        _isAnimatingCard = false;
        _cardTransitionController.value = 0;
      }
    });
    if (isFirstFrame) {
      _updateStackProgress(0);
    }
    if (!_hasStartedPlayback && loadedCount >= _initialFrameThreshold) {
      _hasStartedPlayback = true;
      _startPlayback();
      _logPlaybackStart(_expectedFrameCount);
    }
  }

  Future<void> _buildFramesInParallel({
    required List<EnteFile> files,
    required void Function(_TimelineFrame builtFrame) onFrameReady,
  }) async {
    final readyFrames = <int, _TimelineFrame?>{};
    final completer = Completer<void>();
    int nextEmitIndex = 0;
    int inFlight = 0;
    int started = 0;

    void maybeComplete() {
      if (!completer.isCompleted &&
          nextEmitIndex >= files.length &&
          inFlight == 0 &&
          started >= files.length) {
        completer.complete();
      }
    }

    void emitReady() {
      while (readyFrames.containsKey(nextEmitIndex)) {
        final _TimelineFrame? built = readyFrames.remove(nextEmitIndex);
        if (built != null) {
          onFrameReady(built);
        }
        nextEmitIndex += 1;
      }
      maybeComplete();
    }

    void startNext() {
      while (inFlight < _frameBuildConcurrency && started < files.length) {
        final int index = started;
        started += 1;
        inFlight += 1;
        final file = files[index];
        _buildFrame(file).then((built) {
          readyFrames[index] = built;
        }).catchError((error, stackTrace) {
          readyFrames[index] = null;
        }).whenComplete(() {
          inFlight -= 1;
          emitReady();
          startNext();
        });
      }
      maybeComplete();
    }

    startNext();
    return completer.future;
  }

  Future<_TimelineFrame> _buildFrame(EnteFile file) async {
    MemoryImage? image;
    try {
      final bytes = await getThumbnail(file);
      if (bytes != null && bytes.isNotEmpty) {
        image = MemoryImage(bytes);
      }
    } catch (error, stackTrace) {
      _logger.warning(
        "Failed to fetch thumbnail for ${file.tag}",
        error,
        stackTrace,
      );
    }
    final int creationMicros =
        file.creationTime ?? DateTime.now().microsecondsSinceEpoch;
    final creationDate = DateTime.fromMicrosecondsSinceEpoch(creationMicros);
    final timelineFrame = _TimelineFrame(
      image: image,
      creationDate: creationDate,
    );
    return timelineFrame;
  }

  void _scheduleCardGapUpdate(double candidateGap) {
    if ((_cardGap - candidateGap).abs() <= _cardGapUpdateTolerance) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if ((_cardGap - candidateGap).abs() <= _cardGapUpdateTolerance) {
        return;
      }
      setState(() {
        _cardGap = candidateGap;
      });
    });
  }

  void _scheduleControlsHeightUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final context = _controlsKey.currentContext;
      if (context == null) {
        return;
      }
      final Size? size = context.size;
      if (size == null) {
        return;
      }
      final double height = size.height;
      if ((_controlsHeight - height).abs() <= _controlsHeightUpdateTolerance) {
        return;
      }
      setState(() {
        _controlsHeight = height;
      });
    });
  }

  void _logPlaybackStart(int frameCount) {
    if (_loggedPlaybackStart) return;
    _logger.info(
      "playback_start frames=$frameCount",
    );
    _loggedPlaybackStart = true;
  }

  void _startPlayback() {
    _playTimer?.cancel();
    if (_frames.isEmpty) return;
    _playTimer = Timer.periodic(_frameInterval, (_) {
      if (!mounted || !_isPlaying || _frames.isEmpty) return;
      _showNextFrame();
    });
    setState(() {
      _isPlaying = true;
    });
  }

  void _pausePlayback() {
    _playTimer?.cancel();
    setState(() {
      _isPlaying = false;
    });
  }

  void _showNextFrame() {
    if (_frames.isEmpty || _isAnimatingCard) return;
    if (_currentIndex >= _frames.length - 1) {
      _pausePlayback();
      return;
    }
    final nextIndex = _currentIndex + 1;
    _setCurrentFrame(nextIndex);
  }

  void _setCurrentFrame(int index) {
    _animateToIndex(index);
  }

  void _animateToIndex(int index) {
    if (_frames.isEmpty) {
      return;
    }
    final clamped = index.clamp(0, _frames.length - 1);
    final targetProgress = clamped.toDouble();
    if (!_isAnimatingCard && clamped == _currentIndex) {
      setState(() {
        _sliderValue = targetProgress;
      });
      _updateStackProgress(targetProgress);
      return;
    }

    if (_isAnimatingCard && _targetIndex == clamped) {
      return;
    }

    _animationStartProgress = _stackProgress;
    _targetIndex = clamped;
    _isAnimatingCard = true;
    final distance = (targetProgress - _animationStartProgress).abs();
    final multiplier = distance.clamp(1.0, 4.0);
    _cardTransitionController.duration = Duration(
      milliseconds:
          (_cardTransitionDuration.inMilliseconds * multiplier).round(),
    );
    _cardTransitionController
      ..reset()
      ..forward();
    setState(() {
      _sliderValue = targetProgress;
    });
  }

  void _handleCardDragStart(DragStartDetails details) {
    if (_frames.length <= 1) {
      return;
    }
    _pausePlayback();
    _isAnimatingCard = false;
    _cardTransitionController.stop();
    _dragStartProgress = _stackProgress;
    _dragDistance = 0;
    setState(() {
      _isScrubbing = true;
    });
  }

  void _handleCardDragUpdate(
    DragUpdateDetails details,
    double cardWidth,
  ) {
    if (_frames.length <= 1) {
      return;
    }
    final start = _dragStartProgress;
    if (start == null) {
      return;
    }
    _dragDistance += details.delta.dx;
    final double effectiveWidth = math.max(1, cardWidth);
    final double deltaProgress =
        -(_dragDistance / effectiveWidth) * _dragProgressPerCardWidth;
    final double nextProgress = (start + deltaProgress).clamp(
      0.0,
      (_frames.length - 1).toDouble(),
    );
    _updateStackProgress(nextProgress);
    setState(() {
      _sliderValue = nextProgress;
      _currentIndex = nextProgress.round().clamp(0, _frames.length - 1);
      _isScrubbing = true;
    });
  }

  void _handleCardDragEnd(DragEndDetails details) {
    if (_frames.length <= 1) {
      return;
    }
    final int maxIndex = _frames.length - 1;
    int targetIndex = _stackProgress.round().clamp(0, maxIndex);
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() >= _swipeVelocityThreshold) {
      if (velocity < 0) {
        targetIndex = math.min(maxIndex, targetIndex + 1);
      } else {
        targetIndex = math.max(0, targetIndex - 1);
      }
    }
    _dragStartProgress = null;
    _dragDistance = 0;
    setState(() {
      _isScrubbing = false;
    });
    _animateToIndex(targetIndex);
  }

  void _handleCardDragCancel() {
    if (_frames.length <= 1) {
      return;
    }
    final int maxIndex = _frames.length - 1;
    final int targetIndex = _stackProgress.round().clamp(0, maxIndex);
    _dragStartProgress = null;
    _dragDistance = 0;
    setState(() {
      _isScrubbing = false;
    });
    _animateToIndex(targetIndex);
  }

  @override
  Widget build(BuildContext context) {
    if (!_featureEnabled) {
      return _wrapGuestViewPopScope(
        Theme(
          data: lightThemeData,
          child: Builder(
            builder: (context) {
              final l10n = context.l10n;
              final colorScheme = getEnteColorScheme(context);
              final textTheme = getEnteTextTheme(context);
              return Scaffold(
                backgroundColor: colorScheme.backgroundBase,
                appBar: AppBar(
                  backgroundColor: colorScheme.backgroundBase,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  foregroundColor: colorScheme.textBase,
                  title: const Text("Slideshow"),
                ),
                body: Center(
                  child: Text(
                    l10n.facesTimelineUnavailable,
                    style: textTheme.body.copyWith(
                      color: colorScheme.textBase,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    final Widget content = Theme(
      data: lightThemeData,
      child: Builder(
        builder: (context) {
          final l10n = context.l10n;
          const title = "Slideshow";
          final colorScheme = getEnteColorScheme(context);
          final textTheme = getEnteTextTheme(context);
          final titleStyle = textTheme.h2Bold.copyWith(
            letterSpacing: -2,
          );
          return Scaffold(
            backgroundColor: colorScheme.backgroundBase,
            appBar: AppBar(
              backgroundColor: colorScheme.backgroundBase,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: colorScheme.textBase,
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  const SizedBox(
                    width: _appBarSideWidth,
                    height: kToolbarHeight,
                    child: BackButton(),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        title,
                        style: titleStyle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: _appBarSideWidth),
                ],
              ),
            ),
            body: Stack(
              children: [
                if (_timelineUnavailable && _allFramesLoaded)
                  Center(
                    child: Text(
                      l10n.facesTimelineUnavailable,
                      style: textTheme.body,
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final viewPadding = MediaQuery.of(context).viewPadding;
                      final double bottomInset = viewPadding.bottom;
                      final double bottomPadding = math.max(12, bottomInset);
                      const double topPadding = 12;
                      final double gapToTop = _cardGap + topPadding;
                      const double desiredGap = _controlsDesiredGapToCard;
                      final double overlap = math.max(0, gapToTop - desiredGap);
                      final double controlsHeight = _controlsHeight > 0
                          ? _controlsHeight
                          : _controlsHeightFallback;
                      final double reservedHeight =
                          topPadding + bottomPadding + controlsHeight;
                      final Widget controlsContent = KeyedSubtree(
                        key: _controlsKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildControls(context),
                          ],
                        ),
                      );
                      _scheduleControlsHeightUpdate();
                      return Stack(
                        children: [
                          Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: ValueListenableBuilder<double>(
                                        valueListenable: _stackProgressNotifier,
                                        builder: (context, stackProgress, _) {
                                          return _buildFrameView(
                                            context,
                                            stackProgress,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: reservedHeight),
                            ],
                          ),
                          Positioned(
                            left: 24,
                            right: 24,
                            bottom: bottomPadding + overlap,
                            child: controlsContent,
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
    return _wrapGuestViewPopScope(content);
  }

  Widget _wrapGuestViewPopScope(Widget child) {
    if (!_isGuestView) {
      return child;
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        final authenticated = await _requestAuthentication();
        if (!authenticated || !mounted) {
          return;
        }
        setState(() {
          _isGuestView = false;
        });
        Bus.instance.fire(GuestViewEvent(false, false));
        await localSettings.setOnGuestView(false);
      },
      child: child,
    );
  }

  Future<bool> _requestAuthentication() async {
    return LocalAuthenticationService.instance.requestLocalAuthentication(
      context,
      "Please authenticate to view more photos and videos.",
    );
  }

  Widget _buildFrameView(BuildContext context, double currentStackProgress) {
    final colorScheme = getEnteColorScheme(context);
    if (_frames.isEmpty) {
      return Center(
        key: const ValueKey<String>("faces_timeline_empty"),
        child: FractionallySizedBox(
          widthFactor: _frameWidthFactor,
          heightFactor: _frameHeightFactor,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.backgroundElevated,
              borderRadius: BorderRadius.circular(28),
              boxShadow: (Theme.of(context).brightness == Brightness.dark)
                  ? shadowFloatDark
                  : shadowFloatLight,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: ColoredBox(
                color: colorScheme.backgroundElevated2,
                child: Center(
                  child: Icon(
                    Icons.photo_outlined,
                    size: 72,
                    color: colorScheme.strokeMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final stackProgress = currentStackProgress.clamp(
      0.0,
      (_frames.length - 1).toDouble(),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final List<_CardSlice> slices = [];
    final startIndex = math.max(0, stackProgress.floor() - 3);
    final endIndex = math.min(_frames.length - 1, stackProgress.ceil() + 4);

    for (int i = startIndex; i <= endIndex; i++) {
      final distance = i - stackProgress;
      if (distance < -4.5 || distance > 5.5) {
        continue;
      }
      slices.add(_CardSlice(index: i, distance: distance));
    }

    return Center(
      child: FractionallySizedBox(
        widthFactor: _frameWidthFactor,
        heightFactor: _frameHeightFactor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardHeight = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : constraints.biggest.height;
            final cardWidth = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : constraints.biggest.width;
            if (cardHeight > 0) {
              final double parentHeight = cardHeight / _frameHeightFactor;
              final double gap = math.max(0, (parentHeight - cardHeight) / 2);
              _scheduleCardGapUpdate(gap);
            }
            final double animationDirection = _isAnimatingCard
                ? (_targetIndex.toDouble() - _animationStartProgress).sign
                : 1.0;
            final orderedSlices = slices.toList()
              ..sort((a, b) {
                final int depth = b.distance.abs().compareTo(a.distance.abs());
                if (depth != 0) {
                  return depth;
                }
                final double aDistance = a.distance * animationDirection;
                final double bDistance = b.distance * animationDirection;
                final int direction = aDistance.compareTo(bDistance);
                if (direction != 0) {
                  return direction;
                }
                return a.index.compareTo(b.index);
              });
            final children = orderedSlices.isEmpty
                ? [
                    _MemoryLaneCard(
                      key: ValueKey<int>(_currentIndex),
                      frame: _frames[_currentIndex],
                      distance: 0,
                      isDarkMode: isDark,
                      colorScheme: colorScheme,
                      cardHeight: cardHeight,
                      cardWidth: cardWidth,
                      blurEnabled: !_isScrubbing,
                      showDate: _showPhotoDate,
                    ),
                  ]
                : orderedSlices
                    .map(
                      (slice) => _MemoryLaneCard(
                        key: ValueKey<int>(slice.index),
                        frame: _frames[slice.index],
                        distance: slice.distance,
                        isDarkMode: isDark,
                        colorScheme: colorScheme,
                        cardHeight: cardHeight,
                        cardWidth: cardWidth,
                        blurEnabled: !_isScrubbing,
                        showDate: _showPhotoDate,
                      ),
                    )
                    .toList();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart:
                  _frames.length > 1 ? _handleCardDragStart : null,
              onHorizontalDragUpdate: _frames.length > 1
                  ? (details) => _handleCardDragUpdate(
                        details,
                        cardWidth,
                      )
                  : null,
              onHorizontalDragEnd:
                  _frames.length > 1 ? _handleCardDragEnd : null,
              onHorizontalDragCancel:
                  _frames.length > 1 ? _handleCardDragCancel : null,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: children,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final frameCount = _frames.length;
    final bool hasMultipleFrames = frameCount > 1;
    final double maxValue =
        hasMultipleFrames ? (frameCount - 1).toDouble() : 0.0;
    final double sliderValue =
        hasMultipleFrames ? _sliderValue.clamp(0.0, maxValue) : 0.0;
    final Color activeTrackColor = isDark ? Colors.white : colorScheme.fillBase;
    final Color inactiveTrackColor =
        (isDark ? colorScheme.fillBaseGrey : colorScheme.strokeMuted)
            .withValues(alpha: isDark ? 0.55 : 0.48);
    final Color thumbColor = activeTrackColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: activeTrackColor,
            inactiveTrackColor: inactiveTrackColor,
            thumbColor: thumbColor,
            overlayColor: Colors.transparent,
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const _MemoryLaneSliderThumbShape(),
          ),
          child: Slider(
            value: sliderValue.toDouble(),
            min: 0.0,
            max: frameCount > 1 ? maxValue : 0.0,
            onChangeStart: frameCount > 1
                ? (value) {
                    _pausePlayback();
                    _isAnimatingCard = false;
                    _cardTransitionController.stop();
                    setState(() {
                      _isScrubbing = true;
                    });
                  }
                : null,
            onChanged: frameCount > 1
                ? (value) {
                    final clamped = value.clamp(0.0, maxValue);
                    _updateStackProgress(clamped);
                    setState(() {
                      _sliderValue = clamped;
                      _currentIndex = clamped.round().clamp(0, frameCount - 1);
                      _isScrubbing = true;
                    });
                  }
                : null,
            onChangeEnd: frameCount > 1
                ? (value) {
                    final target =
                        value.round().clamp(0, frameCount - 1).toInt();
                    final double targetProgress = target.toDouble();
                    setState(() {
                      _currentIndex = target;
                      _sliderValue = targetProgress;
                      _isScrubbing = false;
                    });
                    _updateStackProgress(targetProgress);
                  }
                : null,
          ),
        ),
      ],
    );
  }

  void _onCardAnimationTick() {
    if (!_cardTransitionController.isAnimating && !_isAnimatingCard) {
      return;
    }
    final eased =
        Curves.easeInOutCubic.transform(_cardTransitionController.value);
    final progress = ui.lerpDouble(
      _animationStartProgress,
      _targetIndex.toDouble(),
      eased,
    );
    if (progress == null) {
      return;
    }
    _updateStackProgress(progress);
  }

  void _onCardAnimationStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    if (_frames.isEmpty) {
      setState(() {
        _isAnimatingCard = false;
      });
      _updateStackProgress(0);
      return;
    }
    final clampedIndex = _targetIndex.clamp(0, _frames.length - 1);
    setState(() {
      _isAnimatingCard = false;
      _currentIndex = clampedIndex;
      _sliderValue = clampedIndex.toDouble();
    });
    _updateStackProgress(clampedIndex.toDouble());
  }
}

class _TimelineFrame {
  final MemoryImage? image;
  final DateTime creationDate;

  _TimelineFrame({
    required this.image,
    required this.creationDate,
  });
}

class _CardSlice {
  final int index;
  final double distance;

  const _CardSlice({
    required this.index,
    required this.distance,
  });
}

class _MemoryLaneCard extends StatelessWidget {
  static const double _cardRadius = 28;
  static const double _cardBorderWidth = 12;
  static const double _stackOffsetFalloff = 0.62;
  static const double _stackOffsetXFactor = 0.26;
  static const double _stackOffsetYFactor = 0.20;
  static const double _rotationFalloff = 0.20;
  static const double _maxRotation = 0.21; // ~12°
  static const double _opacityBase = 0.62;

  final _TimelineFrame frame;
  final double distance;
  final bool isDarkMode;
  final EnteColorScheme colorScheme;
  final double cardHeight;
  final double cardWidth;
  final bool blurEnabled;
  final bool showDate;

  const _MemoryLaneCard({
    required this.frame,
    required this.distance,
    required this.isDarkMode,
    required this.colorScheme,
    required this.cardHeight,
    required this.cardWidth,
    required this.blurEnabled,
    required this.showDate,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final scale = _calculateScale(distance);
    final xOffset = _calculateXOffset(distance);
    final yOffset = _calculateYOffset(distance);
    final opacity = _calculateOpacity(distance);
    final blurSigma = blurEnabled ? _calculateBlur(distance) : 0.0;
    final rotation = _calculateRotation(distance);

    final cardShadow = _shadowForCard(distance);
    double dateOpacity = 0;
    double textShadowAlpha = 0;
    double dateYOffset = 0;
    double dateScale = 1;
    String? formattedDate;
    TextStyle? dateTextStyle;
    if (showDate) {
      // Emphasize the active card by delaying the date reveal until the card is
      // nearly centered; keeps background cards calm while the primary one lifts.
      final double emphasisDistance = distance.abs();
      final double activation = (1 - (emphasisDistance * 1.8)).clamp(0.0, 1.0);
      final double emphasis = Curves.easeOutQuad.transform(activation);
      dateOpacity = emphasis;
      textShadowAlpha = 0.5 * emphasis;
      dateYOffset = ui.lerpDouble(28, 0, emphasis) ?? 0;
      dateScale = ui.lerpDouble(0.94, 1, emphasis) ?? 1;
      final String localeTag = Localizations.localeOf(context).toLanguageTag();
      formattedDate = DateFormat(
        "d MMM yyyy",
        localeTag,
      ).format(frame.creationDate.toLocal());
      final textTheme = getEnteTextTheme(context);
      dateTextStyle = textTheme.smallMuted.copyWith(
        shadows: [
          Shadow(
            color: Colors.black.withValues(alpha: textShadowAlpha),
            blurRadius: 12,
          ),
        ],
      );
    }

    final cardContent = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(
          color: Colors.white,
          width: _cardBorderWidth,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildImage(blurSigma),
            if (frame.image == null)
              Center(
                child: Icon(
                  Icons.photo_outlined,
                  size: 72,
                  color: colorScheme.strokeMuted,
                ),
              ),
            if (showDate && formattedDate != null && dateTextStyle != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Opacity(
                  opacity: dateOpacity,
                  child: Transform.translate(
                    offset: Offset(0, dateYOffset),
                    child: Transform.scale(
                      scale: dateScale,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 36, 20, 20),
                        child: Text(
                          formattedDate,
                          textAlign: TextAlign.center,
                          style: dateTextStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(xOffset, yOffset),
            child: Transform.rotate(
              angle: rotation,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.center,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_cardRadius),
                    boxShadow: cardShadow,
                  ),
                  child: cardContent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(double blurSigma) {
    final Widget base = frame.image != null
        ? Image(
            image: frame.image!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
          )
        : ColoredBox(
            color: colorScheme.backgroundElevated2,
          );
    if (blurSigma <= 0) {
      return base;
    }
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
      ),
      child: base,
    );
  }

  List<BoxShadow> _shadowForCard(double distance) {
    if (isDarkMode) {
      const double baseOpacity = 0.55;
      if (distance > 0) {
        return [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: math.max(0.0, baseOpacity - distance * 0.12),
            ),
            blurRadius: 38,
            offset: const Offset(0, 26),
            spreadRadius: -6,
          ),
        ];
      }
      final dampening = math.max(0.2, 1 - distance.abs() * 0.25);
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: baseOpacity * dampening),
          blurRadius: 34,
          offset: const Offset(0, 24),
          spreadRadius: -12,
        ),
      ];
    }

    final double dampening = math.max(0.2, 1 - distance.abs() * 0.2);
    if (distance > 0) {
      final double primaryAlpha = math.max(0.0, 0.26 - distance * 0.08);
      final double secondaryAlpha = math.max(0.0, 0.12 - distance * 0.04);
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: primaryAlpha),
          blurRadius: 46,
          offset: const Offset(0, 30),
          spreadRadius: -10,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: secondaryAlpha),
          blurRadius: 14,
          offset: const Offset(0, 10),
          spreadRadius: 0,
        ),
      ];
    }

    final double primaryAlpha = 0.26 * dampening;
    final double secondaryAlpha = 0.12 * dampening;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: primaryAlpha),
        blurRadius: 48,
        offset: const Offset(0, 32),
        spreadRadius: -10,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: secondaryAlpha),
        blurRadius: 16,
        offset: const Offset(0, 10),
        spreadRadius: 0,
      ),
    ];
  }

  double _calculateScale(double distance) {
    final double d = distance.abs();
    if (d <= 0) {
      return 1.0;
    }
    final double t = (1 - math.pow(0.66, d).toDouble()).clamp(0.0, 1.0);
    return (1.0 - (0.06 * t)).clamp(0.9, 1.0);
  }

  double _stackDisplacement(double distance, double perStep) {
    final double d = distance.abs();
    if (d <= 0) {
      return 0.0;
    }
    final double magnitude = (1 - math.pow(_stackOffsetFalloff, d).toDouble()) /
        (1 - _stackOffsetFalloff);
    return perStep * magnitude * distance.sign;
  }

  double _calculateXOffset(double distance) {
    final double base = math.min(cardWidth, cardHeight);
    return _stackDisplacement(distance, base * _stackOffsetXFactor);
  }

  double _calculateYOffset(double distance) {
    final double base = math.min(cardWidth, cardHeight);
    return _stackDisplacement(distance, base * _stackOffsetYFactor);
  }

  double _calculateBlur(double distance) {
    final double d = distance.abs();
    if (d <= 0) {
      return 0;
    }
    const double clearDistance = 0.15;
    const double blurMultiplier = 4.5;
    final double effective = math.max(0, d - clearDistance);
    return math.min(
      12,
      (effective + 0.05) * blurMultiplier,
    );
  }

  double _calculateRotation(double distance) {
    final double d = distance.abs();
    if (d <= 0) {
      return 0;
    }
    final double t =
        (1 - math.pow(_rotationFalloff, d).toDouble()).clamp(0.0, 1.0);
    return _maxRotation * t * distance.sign;
  }

  double _calculateOpacity(double distance) {
    final double d = distance.abs();
    if (d <= 0) {
      return 1.0;
    }
    return math.pow(_opacityBase, d).toDouble().clamp(0.0, 1.0);
  }
}

class _MemoryLaneSliderThumbShape extends SliderComponentShape {
  const _MemoryLaneSliderThumbShape();

  static const double _thumbRadius = 12;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_thumbRadius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required ui.TextDirection textDirection,
    required double textScaleFactor,
    required double value,
    required Size sizeWithOverflow,
  }) {
    final Color color =
        sliderTheme.thumbColor ?? sliderTheme.activeTrackColor ?? Colors.white;
    final canvas = context.canvas;
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    canvas.drawCircle(center.translate(0, 1), _thumbRadius, shadowPaint);
    final paint = Paint()..color = color;
    canvas.drawCircle(center, _thumbRadius, paint);
  }
}
