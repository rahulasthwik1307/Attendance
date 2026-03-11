import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';
import '../../widgets/fade_slide_y.dart';

class RegistrationSuccessScreen extends StatefulWidget {
  const RegistrationSuccessScreen({super.key});

  @override
  State<RegistrationSuccessScreen> createState() =>
      _RegistrationSuccessScreenState();
}

class _RegistrationSuccessScreenState extends State<RegistrationSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _checkController.forward();
    // No timer — student stays here until they manually check status
  }

  Future<void> _checkApprovalStatus() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final data = await Supabase.instance.client
        .from('students')
        .select('is_approved, is_rejected')
        .eq('id', user.id)
        .maybeSingle();

    if (!mounted) return;

    if (data == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not fetch status. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final bool isApproved = data['is_approved'] == true;
    final bool isRejected = data['is_rejected'] == true;

    if (isApproved) {
      AuthFlowState.instance.passwordSet = true;
      AuthFlowState.instance.faceRegistered = true;
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil('/dashboard', (route) => false);
    } else if (isRejected) {
      // Show rejection dialog then redirect to home
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Registration Rejected',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
          ),
          content: const Text(
            'Your face registration was rejected by your teacher. Please re-register your face.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppStyles.primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      // Reset auth flow state and go to home
      AuthFlowState.instance.faceRegistered = false;
      AuthFlowState.instance.passwordSet = true;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not approved yet. Please wait for your teacher.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // Ripple effect
                AnimatedBuilder(
                  animation: _rippleController,
                  builder: (context, child) {
                    return Container(
                      width: 150 + (_rippleController.value * 50),
                      height: 150 + (_rippleController.value * 50),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppStyles.successGreen.withValues(
                          alpha: 1 - _rippleController.value,
                        ),
                      ),
                    );
                  },
                ),
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      color: AppStyles.successGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 48),
            const FadeSlideY(
              delay: Duration(milliseconds: 300),
              child: Text(
                'Registration Submitted',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppStyles.textDark,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const FadeSlideY(
              delay: Duration(milliseconds: 400),
              child: Text(
                'Awaiting teacher approval',
                style: TextStyle(fontSize: 16, color: AppStyles.textGray),
              ),
            ),
            const SizedBox(height: 32),
            FadeSlideY(
              delay: const Duration(milliseconds: 500),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: ElevatedButton(
                  onPressed: _checkApprovalStatus,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppStyles.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    minimumSize: const Size(double.infinity, 48),
                  ),
                  child: const Text(
                    'Check Approval Status',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
