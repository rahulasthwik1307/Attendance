import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

class ActivateAccountScreen extends StatefulWidget {
  const ActivateAccountScreen({super.key});

  @override
  State<ActivateAccountScreen> createState() => _ActivateAccountScreenState();
}

class _ActivateAccountScreenState extends State<ActivateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _rollController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _rollController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onContinue() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pushNamed('/set_password');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final cardColor = theme.cardTheme.color ?? Colors.white;
    final inputFill = isDark
        ? AppStyles.surfaceDark.withValues(alpha: 0.6)
        : AppStyles.backgroundLight;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),

              // ── Icon Hero ────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 60),
                child: Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.face_retouching_natural_rounded,
                          color: theme.primaryColor.withValues(alpha: 0.35),
                          size: 44,
                        ),
                        Positioned(
                          bottom: 10,
                          right: 10,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: cardColor,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.shield_rounded,
                              color: theme.primaryColor,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(flex: 2),

              // ── Title ────────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 160),
                child: Text(
                  'Activate Your Account',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: headingColor,
                    height: 1.15,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Subtitle ─────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 240),
                child: Text(
                  'Enter your institution credentials to get started.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: subtitleColor,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const Spacer(flex: 3),

              // ── Form ─────────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 340),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Roll Number field
                      _InputField(
                        controller: _rollController,
                        label: 'Roll Number',
                        hint: 'e.g. 2023-CS-001',
                        prefixIcon: Icons.badge_outlined,
                        fillColor: inputFill,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.next,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Please enter your roll number'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      // Password field
                      _InputField(
                        controller: _passwordController,
                        label: 'Default Password',
                        hint: '••••••••',
                        prefixIcon: Icons.lock_outline_rounded,
                        fillColor: inputFill,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _onContinue(),
                        validator: (v) => (v == null || v.length < 4)
                            ? 'Password must be at least 4 characters'
                            : null,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: AppStyles.textGray,
                            size: 20,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(flex: 3),

              // ── Primary CTA ──────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 460),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: theme.primaryColor.withValues(alpha: 0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: AnimatedButton(
                    onPressed: _onContinue,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Continue', style: TextStyle(fontSize: 16)),
                        SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              ),

              // ── Bottom trust note ────────────────────────────────────────
              Flexible(
                fit: FlexFit.loose,
                child: FadeSlideY(
                  delay: const Duration(milliseconds: 560),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 12,
                          color: subtitleColor.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Your credentials are encrypted and secure.',
                          style: TextStyle(
                            fontSize: 12,
                            color: subtitleColor.withValues(alpha: 0.5),
                            fontWeight: FontWeight.w500,
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
    );
  }
}

// ─── Reusable styled input field ──────────────────────────────────────────────
class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData prefixIcon;
  final Color fillColor;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;
  final void Function(String)? onFieldSubmitted;

  const _InputField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.prefixIcon,
    required this.fillColor,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.next,
    this.validator,
    this.suffixIcon,
    this.onFieldSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark ? Colors.white12 : const Color(0xFFDDE4ED);

    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(
          color: AppStyles.textGray,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: TextStyle(
          color: AppStyles.textGray.withValues(alpha: 0.5),
          fontSize: 14,
        ),
        prefixIcon: Icon(prefixIcon, color: AppStyles.textGray, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: fillColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.primaryColor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppStyles.errorRed, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppStyles.errorRed, width: 1.5),
        ),
      ),
    );
  }
}
