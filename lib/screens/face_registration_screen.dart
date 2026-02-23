import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../utils/auth_flow_state.dart';

class FaceRegistrationScreen extends StatefulWidget {
  const FaceRegistrationScreen({super.key});

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _textFadeController;

  final Map<String, String> _subtitles = {
    "Fit your face in the circle": "Make sure your full face is visible",
    "Move closer": "Step a little closer to the camera",
    "Move back": "You are too close, step back slightly",
    "Move left": "Shift your position slightly to the left",
    "Move right": "Shift your position slightly to the right",
    "Hold still…": "Almost done, stay steady",
    "Blink to verify": "Blink naturally to confirm you are present",
  };

  final List<String> _instructions = [
    "Fit your face in the circle",
    "Move closer",
    "Move back",
    "Move left",
    "Move right",
    "Hold still…",
    "Blink to verify",
  ];
  int _instructionIndex = 0;

  @override
  void initState() {
    super.initState();

    // Security Guard: Prevent access if password hasn't been set/activated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AuthFlowState.instance.passwordSet) {
        Navigator.of(context).pushReplacementNamed('/sign_in');
      }
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _cycleInstructions();
  }

  void _cycleInstructions() async {
    for (int i = 0; i < _instructions.length; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) break;

      await _textFadeController.reverse();
      setState(() {
        _instructionIndex = i;
      });
      await _textFadeController.forward();

      // After final instruction, auto-simulate capture and go to success screen
      if (i == _instructions.length - 1) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/registration_success');
        }
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _textFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final circleSize = screenSize.width * 0.75;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              children: [
                // Top App Bar Area
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 16.0,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 48), // Balance for icon button
                      const Spacer(),
                      Column(
                        children: [
                          Text(
                            'Step 2 of 3',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF4A5568),
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                          Text(
                            'Face Registration',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A202C),
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      const SizedBox(width: 48), // Balance for icon button
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24.0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Simulated Camera Feed Placeholder
                      ClipOval(
                        child: Container(
                          width: circleSize,
                          height: circleSize,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            image: const DecorationImage(
                              image: NetworkImage(
                                'https://picsum.photos/400/400?grayscale',
                              ),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),

                      // Frosted Glass Overlay outside circle is not easily doable with single standard ClipPath unless we invert it.
                      // Instead we use a ColorFiltered or CustomPaint over the entire screen except the circle.
                      ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          Colors.white.withValues(alpha: 0.8),
                          BlendMode.srcOut,
                        ),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.transparent,
                          ),
                          child: Container(
                            width: circleSize,
                            height: circleSize,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),

                      // Pulsing Glow Border
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: circleSize,
                            height: circleSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppStyles.primaryBlue,
                                width: 2.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: AppStyles.primaryBlue.withAlpha(
                                    (_pulseController.value * 255 * 0.5)
                                        .toInt(),
                                  ),
                                  blurRadius: 8 + (_pulseController.value * 12),
                                ),
                                BoxShadow(
                                  color: Colors.black.withAlpha(
                                    (0.1 * 255).toInt(),
                                  ),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Instructions
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 24.0,
                    left: 24.0,
                    right: 24.0,
                  ),
                  child: FadeTransition(
                    opacity: _textFadeController,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppStyles.primaryBlue.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _instructions[_instructionIndex],
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppStyles.primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _subtitles[_instructions[_instructionIndex]] ?? '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppStyles.textDark.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
