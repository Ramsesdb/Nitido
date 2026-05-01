import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class NitidoAnimatedLogo extends StatefulWidget {
  final bool showIcon;
  final String? subtitle;
  final double iconSize;
  final double fontSize;
  /// true  → estrella cae desde arriba (Pixar-style) y luego guiña — welcome screen
  /// false → solo guiña (ya está colocada) — onboarding
  final bool animateIn;

  const NitidoAnimatedLogo({
    super.key,
    this.showIcon = true,
    this.subtitle,
    this.iconSize = 96,
    this.fontSize = 40,
    this.animateIn = true,
  });

  @override
  State<NitidoAnimatedLogo> createState() => _NitidoAnimatedLogoState();
}

class _NitidoAnimatedLogoState extends State<NitidoAnimatedLogo>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> starScaleAnim;
  late final Animation<double> starOpacityAnim;
  late final Animation<double> starDropAnim; // Y offset en px: negativo = arriba
  late final AnimationController _levitateController;
  late final Animation<double> levitateAnim;

  @override
  void initState() {
    super.initState();

    if (widget.animateIn) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 3000),
      );

      // Estrella cae 60px desde arriba con rebote al aterrizar
      starDropAnim = Tween<double>(begin: -60.0, end: 0.0)
          .chain(CurveTween(
            curve: const Interval(0.0, 0.38, curve: Curves.bounceOut),
          ))
          .animate(_controller);

      // Escala pequeña → 1 mientras cae (aparece al mismo tiempo)
      starScaleAnim = Tween<double>(begin: 0.1, end: 1.0)
          .chain(CurveTween(
            curve: const Interval(0.0, 0.28, curve: Curves.easeOut),
          ))
          .animate(_controller);

      // Guiña dos veces después de aterrizar
      starOpacityAnim = TweenSequence<double>([
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 8,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 9,
        ),
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 8),
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 8,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 9,
        ),
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 13),
      ]).animate(_controller);

      _levitateController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2500),
      );
      levitateAnim = Tween<double>(begin: -2.5, end: 2.5)
          .chain(CurveTween(curve: Curves.easeInOut))
          .animate(_levitateController);
    } else {
      // Onboarding: solo parpadeo, sin caída
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000),
      );

      starDropAnim = ConstantTween<double>(0.0).animate(_controller);
      starScaleAnim = ConstantTween<double>(1.0).animate(_controller);

      starOpacityAnim = TweenSequence<double>([
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 20),
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 12,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 13,
        ),
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 15),
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 12,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 13,
        ),
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 15),
      ]).animate(_controller);

      _levitateController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2500),
      );
      levitateAnim = Tween<double>(begin: -2.5, end: 2.5)
          .chain(CurveTween(curve: Curves.easeInOut))
          .animate(_levitateController);
    }

    _controller.forward().then((_) {
      if (mounted) _levitateController.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _levitateController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = GoogleFonts.gabarito(
      fontWeight: FontWeight.w900,
      fontSize: widget.fontSize,
      color: Colors.white,
      letterSpacing: -1.0,
    );

    final subtitleStyle = GoogleFonts.gabarito(
      fontWeight: FontWeight.w400,
      fontSize: widget.fontSize * 0.42,
      color: Colors.white.withValues(alpha: 0.65),
      letterSpacing: 0.2,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showIcon) ...[
          Image.asset(
            'assets/resources/nitido_n_icon_sin.png',
            width: widget.iconSize,
            height: widget.iconSize,
          ),
          const SizedBox(height: 24),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('N', style: textStyle),
            Stack(
              clipBehavior: Clip.none,
              children: [
                Text('ı', style: textStyle),
                Positioned(
                  top: widget.fontSize * 0.16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_controller, _levitateController]),
                      builder: (_, child) => Transform.translate(
                        offset: Offset(0, starDropAnim.value + levitateAnim.value),
                        child: ScaleTransition(
                          scale: starScaleAnim,
                          child: FadeTransition(
                            opacity: starOpacityAnim,
                            child: child!,
                          ),
                        ),
                      ),
                      child: Text(
                        '✦',
                        style: TextStyle(
                          fontSize: widget.fontSize * 0.28,
                          color: const Color(0xFF00897B),
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Text('TIDO', style: textStyle),
          ],
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 12),
          Text(widget.subtitle!, style: subtitleStyle),
        ],
      ],
    );
  }
}
