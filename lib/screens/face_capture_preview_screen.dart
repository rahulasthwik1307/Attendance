import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';
import '../utils/auth_flow_state.dart';

class FaceCapturePreviewScreen extends StatelessWidget {
  const FaceCapturePreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppStyles.textDark,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
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
              const FadeSlideY(
                delay: Duration(milliseconds: 100),
                child: Text(
                  'Make sure your face is clearly visible and well-lit.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppStyles.textGray,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 48),
              FadeSlideY(
                delay: const Duration(milliseconds: 200),
                child: Center(
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
              const Spacer(),
              FadeSlideY(
                delay: const Duration(milliseconds: 300),
                child: AnimatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: Theme.of(context).outlinedButtonTheme.style,
                  child: const Text('Retake'),
                ),
              ),
              const SizedBox(height: 16),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: AnimatedButton(
                  onPressed: () {
                    AuthFlowState.instance.faceRegistered = true;
                    Navigator.of(
                      context,
                    ).pushNamedAndRemoveUntil('/dashboard', (route) => false);
                  },
                  child: const Text('Save & Verify'),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
