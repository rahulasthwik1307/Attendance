import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import 'animated_button.dart';
import 'fade_slide_y.dart';

class DeleteFacePopup extends StatelessWidget {
  const DeleteFacePopup({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const DeleteFacePopup(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 32),
          const FadeSlideY(
            delay: Duration(milliseconds: 100),
            child: Icon(
              Icons.warning_amber_rounded,
              color: AppStyles.errorRed,
              size: 64,
            ),
          ),
          const SizedBox(height: 16),
          const FadeSlideY(
            delay: Duration(milliseconds: 200),
            child: Text(
              'Delete Face Data?',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppStyles.textDark,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const FadeSlideY(
            delay: Duration(milliseconds: 300),
            child: Text(
              'Are you sure you want to delete your registered face data? You will need to re-register to mark attendance.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppStyles.textGray,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 32),
          FadeSlideY(
            delay: const Duration(milliseconds: 400),
            child: AnimatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushReplacementNamed('/home');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppStyles.errorRed,
                minimumSize: const Size(double.infinity, 56),
              ),
              child: const Text('Delete Data'),
            ),
          ),
          const SizedBox(height: 12),
          FadeSlideY(
            delay: const Duration(milliseconds: 500),
            child: AnimatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppStyles.textGray,
                side: BorderSide(color: Colors.grey.shade300, width: 2),
                minimumSize: const Size(double.infinity, 56),
              ),
              child: const Text('Cancel'),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
