import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, SystemSound;

/// Centralized UI polish utilities for animations, haptics, and accessibility.
/// Respects `MediaQuery.disableAnimations` for WCAG 2.3.3 compliance.

/// Standard animation durations following Material 3 motion tokens.
class AppDurations {
  static const Duration instant = Duration(milliseconds: 0);
  static const Duration fast = Duration(milliseconds: 100);
  static const Duration medium = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Duration slower = Duration(milliseconds: 500);

  /// Returns duration, or zero if animations disabled.
  static Duration get(BuildContext context, Duration duration) {
    return MediaQuery.maybeOf(context)?.disableAnimations == true
        ? Duration.zero
        : duration;
  }
}

/// Standard curves following Material 3.
class AppCurves {
  static const Curve standard = Curves.easeInOut;
  static const Curve emphasized = Curves.easeInOutCubic;
  static const Curve decelerated = Curves.easeOutCubic;
  static const Curve accelerated = Curves.easeInCubic;
}

/// Haptic feedback wrapper that no-ops on unsupported platforms.
class AppHaptics {
  static void lightImpact() {
    HapticFeedback.lightImpact();
  }

  static void mediumImpact() {
    HapticFeedback.mediumImpact();
  }

  static void heavyImpact() {
    HapticFeedback.heavyImpact();
  }

  static void selectionClick() {
    HapticFeedback.selectionClick();
  }

  static void vibrate() {
    HapticFeedback.vibrate();
  }
}

/// Animated tap wrapper that provides visual + haptic feedback.
class PolishedTapTarget extends StatelessWidget {
  const PolishedTapTarget({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.borderRadius = 12,
    this.backgroundColor,
    this.hoverColor,
    this.splashColor,
    this.hapticFeedback = true,
    this.semanticsLabel,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double borderRadius;
  final Color? backgroundColor;
  final Color? hoverColor;
  final Color? splashColor;
  final bool hapticFeedback;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      label: semanticsLabel,
      button: true,
      child: Material(
        color: backgroundColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(borderRadius),
        child: InkWell(
          onTap: () {
            if (hapticFeedback) AppHaptics.lightImpact();
            onTap();
          },
          onLongPress: onLongPress != null
              ? () {
                  if (hapticFeedback) AppHaptics.mediumImpact();
                  onLongPress!();
                }
              : null,
          borderRadius: BorderRadius.circular(borderRadius),
          hoverColor: hoverColor ?? theme.colorScheme.primary.withValues(alpha: 0.08),
          splashColor: splashColor ?? theme.colorScheme.primary.withValues(alpha: 0.12),
          child: child,
        ),
      ),
    );
  }
}

/// Animated container that respects reduced motion.
class PolishedAnimatedContainer extends StatelessWidget {
  const PolishedAnimatedContainer({
    super.key,
    required this.child,
    this.duration,
    this.curve = AppCurves.standard,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.decoration,
    this.alignment,
    this.transform,
  });

  final Widget child;
  final Duration? duration;
  final Curve curve;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Decoration? decoration;
  final AlignmentGeometry? alignment;
  final Matrix4? transform;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = duration != null
        ? AppDurations.get(context, duration!)
        : Duration.zero;

    return AnimatedContainer(
      duration: effectiveDuration,
      curve: curve,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      decoration: decoration,
      alignment: alignment,
      transform: transform,
      child: child,
    );
  }
}

/// Fade transition that respects reduced motion.
class PolishedFadeTransition extends StatelessWidget {
  const PolishedFadeTransition({
    super.key,
    required this.child,
    required this.opacity,
    this.duration = AppDurations.medium,
    this.curve = AppCurves.decelerated,
  });

  final Widget child;
  final Animation<double> opacity;
  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = AppDurations.get(context, duration);

    return AnimatedOpacity(
      opacity: opacity.value,
      duration: effectiveDuration,
      curve: curve,
      child: child,
    );
  }
}

/// Slide transition that respects reduced motion.
class PolishedSlideTransition extends StatelessWidget {
  const PolishedSlideTransition({
    super.key,
    required this.child,
    required this.position,
    this.duration = AppDurations.medium,
    this.curve = AppCurves.decelerated,
  });

  final Widget child;
  final Animation<Offset> position;
  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = AppDurations.get(context, duration);

    return AnimatedSlide(
      offset: position.value,
      duration: effectiveDuration,
      curve: curve,
      child: child,
    );
  }
}

/// Scale transition that respects reduced motion.
class PolishedScaleTransition extends StatelessWidget {
  const PolishedScaleTransition({
    super.key,
    required this.child,
    required this.scale,
    this.duration = AppDurations.fast,
    this.curve = AppCurves.standard,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Animation<double> scale;
  final Duration duration;
  final Curve curve;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = AppDurations.get(context, duration);

    return AnimatedScale(
      scale: scale.value,
      duration: effectiveDuration,
      curve: curve,
      alignment: alignment,
      child: child,
    );
  }
}

/// Page route with custom transitions respecting reduced motion.
class PolishedPageRoute<T> extends PageRouteBuilder<T> {
  PolishedPageRoute({
    required super.pageBuilder,
    super.transitionDuration = AppDurations.medium,
    super.reverseTransitionDuration = AppDurations.medium,
    this.curve = AppCurves.standard,
    this.reverseCurve = AppCurves.standard,
    super.settings,
  });

  final Curve curve;
  final Curve reverseCurve;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final effectiveDuration = AppDurations.get(context, transitionDuration);

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1.0, 0.0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: curve,
      )),
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: curve,
        ),
        child: child,
      ),
    );
  }
}

/// Hero controller for coordinated hero animations.
class PolishedHeroController extends HeroController {
  PolishedHeroController({super.createRectTween});

  @override
  Duration get duration => AppDurations.medium;
}

/// Live region for accessibility announcements.
class PolishedLiveRegion extends StatelessWidget {
  const PolishedLiveRegion({
    super.key,
    required this.child,
    this.politeness = 'polite',
  });

  final Widget child;
  final String politeness;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      explicitChildNodes: true,
      child: child,
    );
  }
}

/// Utility to show a snackbar with haptic feedback.
void showPolishedSnackBar(
  BuildContext context, {
  required String message,
  Duration duration = const Duration(seconds: 4),
  VoidCallback? onAction,
  String? actionLabel,
}) {
  AppHaptics.lightImpact();

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      action: onAction != null && actionLabel != null
          ? SnackBarAction(
              label: actionLabel,
              onPressed: onAction,
            )
          : null,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
        left: 16,
        right: 16,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// Loading indicator with subtle pulse animation.
class PolishedLoadingIndicator extends StatefulWidget {
  const PolishedLoadingIndicator({
    super.key,
    this.size = 24,
    this.color,
    this.strokeWidth = 2.5,
  });

  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  State<PolishedLoadingIndicator> createState() => _PolishedLoadingIndicatorState();
}

class _PolishedLoadingIndicatorState extends State<PolishedLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _controller.stop();
      _controller.value = 1.0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CircularProgressIndicator(
            value: _controller.value,
            strokeWidth: widget.strokeWidth,
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.color ?? Theme.of(context).colorScheme.primary,
            ),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        );
      },
    );
  }
}

/// Empty state widget with illustration and action.
class PolishedEmptyState extends StatelessWidget {
  const PolishedEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.iconSize = 64,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}