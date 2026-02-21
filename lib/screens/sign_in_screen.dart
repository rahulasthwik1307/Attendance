import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen>
    with SingleTickerProviderStateMixin {
  final _rollController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePassword = true;
  bool _isLoading = false;

  // Entrance slide animation
  late AnimationController _entranceController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutCubic,
          ),
        );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOut),
    );

    // Small delay before entrance — consistent with other screens.
    Future.delayed(const Duration(milliseconds: 60), () {
      if (mounted) _entranceController.forward();
    });
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _rollController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onSignIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isLoading = true);

    // Simulate auth delay; replace with real auth call.
    await Future.delayed(const Duration(milliseconds: 900));

    if (!mounted) return;
    setState(() => _isLoading = false);

    Navigator.of(context).pushReplacementNamed('/dashboard');
  }

  void _onForgotPassword() {
    Navigator.of(context).pushNamed('/forgot_password');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final isDark = theme.brightness == Brightness.dark;

    final inputFill = isDark
        ? AppStyles.surfaceDark
        : theme.colorScheme.surface;
    final inputBorder = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(flex: 2),

                    // ── Back button ────────────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 60),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(),
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 20,
                                color: headingColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Title ─────────────────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 120),
                      child: Text(
                        'Sign In',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1.15,
                          color: headingColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),

                    FadeSlideY(
                      delay: const Duration(milliseconds: 180),
                      child: Text(
                        'Welcome back. Enter your credentials to continue.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: subtitleColor,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),

                    const Spacer(flex: 1),

                    // ── Roll Number field ─────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 260),
                      child: _InputLabel(label: 'Roll Number'),
                    ),
                    const SizedBox(height: 8),
                    FadeSlideY(
                      delay: const Duration(milliseconds: 300),
                      child: TextFormField(
                        controller: _rollController,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.next,
                        decoration: _inputDecoration(
                          context: context,
                          hint: 'e.g. 21CS001',
                          prefixIcon: Icons.badge_outlined,
                          fill: inputFill,
                          border: inputBorder,
                          isDark: isDark,
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Please enter your roll number';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Password field ────────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 360),
                      child: _InputLabel(label: 'Password'),
                    ),
                    const SizedBox(height: 8),
                    FadeSlideY(
                      delay: const Duration(milliseconds: 400),
                      child: TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _onSignIn(),
                        decoration:
                            _inputDecoration(
                              context: context,
                              hint: '••••••••',
                              prefixIcon: Icons.lock_outline_rounded,
                              fill: inputFill,
                              border: inputBorder,
                              isDark: isDark,
                            ).copyWith(
                              suffixIcon: IconButton(
                                icon: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    key: ValueKey(_obscurePassword),
                                    size: 20,
                                    color: subtitleColor,
                                  ),
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ),
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Please enter your password';
                          }
                          if (v.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                    ),

                    const Spacer(flex: 2),

                    // ── Primary CTA ───────────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 480),
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
                        child: _isLoading
                            ? _LoadingButton(theme: theme)
                            : AnimatedButton(
                                onPressed: _onSignIn,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 20,
                                  ),
                                  elevation: 0,
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.login_rounded,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Sign In',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Forgot Password ───────────────────────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 560),
                      child: Center(
                        child: TextButton(
                          onPressed: _onForgotPassword,
                          style: TextButton.styleFrom(
                            foregroundColor: theme.primaryColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: const Text(
                            'Forgot Password?',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const Spacer(flex: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

class _InputLabel extends StatelessWidget {
  final String label;
  const _InputLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
        letterSpacing: 0.2,
      ),
    );
  }
}

InputDecoration _inputDecoration({
  required BuildContext context,
  required String hint,
  required IconData prefixIcon,
  required Color fill,
  required Color border,
  required bool isDark,
}) {
  final theme = Theme.of(context);
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      color: (theme.textTheme.bodyMedium?.color ?? AppStyles.textGray)
          .withValues(alpha: 0.45),
      fontSize: 14,
    ),
    filled: true,
    fillColor: fill,
    prefixIcon: Padding(
      padding: const EdgeInsets.only(left: 14, right: 10),
      child: Icon(
        prefixIcon,
        size: 20,
        color: theme.primaryColor.withValues(alpha: 0.75),
      ),
    ),
    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: border, width: 1),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: border, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(
        color: theme.primaryColor.withValues(alpha: 0.75),
        width: 1.5,
      ),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(
        color: AppStyles.errorRed.withValues(alpha: 0.7),
        width: 1.2,
      ),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppStyles.errorRed, width: 1.5),
    ),
  );
}

// A slim scaffold used during the async "sign-in" call.
class _LoadingButton extends StatelessWidget {
  final ThemeData theme;
  const _LoadingButton({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: theme.primaryColor,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}
