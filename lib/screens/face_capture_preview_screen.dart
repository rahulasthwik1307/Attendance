import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';
import '../utils/auth_flow_state.dart';
import 'face_registration_screen.dart';

class FaceCapturePreviewScreen extends StatefulWidget {
  const FaceCapturePreviewScreen({super.key});

  @override
  State<FaceCapturePreviewScreen> createState() =>
      _FaceCapturePreviewScreenState();
}

class _FaceCapturePreviewScreenState extends State<FaceCapturePreviewScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  bool _isLoading = false;
  bool _isSuccess = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scaleAnimation = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        AuthFlowState.instance.passwordSet = true;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const FaceRegistrationScreen()),
          (route) => false,
        );
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: const Text(
            'Preview',
            style: TextStyle(
              color: AppStyles.textDark,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                FadeSlideY(
                  delay: const Duration(milliseconds: 100),
                  child: Text(
                    'Make sure your face is clearly visible and well-lit.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppStyles.textDark.withValues(alpha: 0.65),
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                FadeSlideY(
                  delay: const Duration(milliseconds: 200),
                  child: Center(
                    child: ScaleTransition(
                      scale: _scaleAnimation,
                      child: Container(
                        width: 250,
                        height: 250,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppStyles.primaryBlue.withValues(alpha: 0.5),
                            width: 4,
                          ),
                          image: const DecorationImage(
                            image: NetworkImage(
                              'https://picsum.photos/400/400?grayscale',
                            ),
                            fit: BoxFit.cover,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                FadeSlideY(
                  delay: const Duration(milliseconds: 300),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppStyles.primaryBlue,
                        width: 1.5,
                      ),
                    ),
                    child: AnimatedButton(
                      onPressed: () {
                        AuthFlowState.instance.passwordSet = true;
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(
                            builder: (_) => const FaceRegistrationScreen(),
                          ),
                          (route) => false,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: AppStyles.primaryBlue,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Retake',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppStyles.primaryBlue,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FadeSlideY(
                  delay: const Duration(milliseconds: 400),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: AppStyles.primaryBlue.withValues(alpha: 0.28),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: AnimatedButton(
                      onPressed: () async {
                        if (_isLoading || _isSuccess) return;
                        setState(() => _isLoading = true);
                        await Future.delayed(const Duration(milliseconds: 800));
                        if (!context.mounted) return;
                        setState(() {
                          _isLoading = false;
                          _isSuccess = true;
                        });
                        await Future.delayed(const Duration(milliseconds: 600));
                        if (!context.mounted) return;
                        AuthFlowState.instance.faceRegistered = true;
                        Navigator.of(
                          context,
                        ).pushReplacementNamed('/registration_success');
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppStyles.primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: _isLoading
                              ? const SizedBox(
                                  key: ValueKey('loading'),
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : _isSuccess
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 22,
                                  color: Colors.white,
                                  key: ValueKey('success'),
                                )
                              : Row(
                                  key: const ValueKey('default'),
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    SizedBox(width: 18),
                                    Expanded(
                                      child: Text(
                                        'Save & Verify',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Icon(Icons.arrow_forward_rounded, size: 18),
                                    SizedBox(width: 12),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
