import 'package:flutter/material.dart';
import 'utils/app_styles.dart';
import 'utils/auth_flow_state.dart';

import 'screens/auth/splash_screen.dart' as splash;
import 'screens/auth/home_screen.dart' as home;
import 'screens/face/face_registration_screen.dart' as face_reg;
import 'screens/registration/registration_success_screen.dart' as reg_success;
import 'screens/registration/registration_failed_screen.dart' as reg_fail;
import 'screens/face/face_capture_preview_screen.dart' as preview;
import 'screens/dashboard/dashboard_screen.dart' as dashboard;
import 'screens/dashboard/history_screen.dart' as history;
import 'screens/face/face_verification_screen.dart' as verify;
import 'screens/attendance/attendance_success_screen.dart' as att_success;
import 'screens/attendance/attendance_failed_screen.dart' as att_fail;
import 'screens/attendance/location_error_screen.dart' as loc_error;
import 'screens/dashboard/profile_screen.dart' as profile;
import 'screens/dashboard/settings_screen.dart' as settings_screen;
import 'screens/attendance/qr_precheck_screen.dart' as qr_precheck;
import 'screens/attendance/qr_scanner_screen.dart' as qr_scanner;
import 'screens/attendance/qr_face_verify_screen.dart' as qr_face_verify;
import 'screens/attendance/qr_success_screen.dart' as qr_success;
import 'screens/attendance/qr_timeout_screen.dart' as qr_timeout;
import 'screens/auth/activate_account_screen.dart' as activate;
// Auth & password reset flow
import 'screens/auth/sign_in_screen.dart' as sign_in;
import 'screens/auth/forgot_password_screen.dart' as forgot_pw;
import 'screens/auth/password_reset_face_success_screen.dart'
    as pw_reset_success;
import 'screens/auth/forgot_password_face_verify_screen.dart'
    as forgot_pw_verify;
import 'screens/face/reset_face_verify_screen.dart' as reset_face_verify;
import 'screens/auth/set_new_password_screen.dart' as set_new_pw;
import 'screens/auth/password_updated_screen.dart' as pw_updated;
import 'screens/auth/password_change_success_screen.dart' as pw_change_success;
import 'screens/face/face_updated_success_screen.dart' as face_updated_success;

final ValueNotifier<ThemeMode> appThemeNotifier = ValueNotifier(
  ThemeMode.light,
);

void main() {
  runApp(const SmartAttendanceApp());
}

class SmartAttendanceApp extends StatelessWidget {
  const SmartAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          title: 'Smart Attendance',
          debugShowCheckedModeBanner: false,
          theme: AppStyles.lightTheme,
          darkTheme: AppStyles.darkTheme,
          themeMode: currentMode,
          themeAnimationDuration: const Duration(milliseconds: 400),
          themeAnimationCurve: Curves.easeInOut,
          home: const splash.SplashScreen(),
          onGenerateRoute: (routeSettings) {
            Widget page;
            switch (routeSettings.name) {
              case '/':
              case '/splash':
                page = const splash.SplashScreen();
                break;
              case '/home':
                page = const home.HomeScreen();
                break;
              case '/register':
                if (AuthFlowState.instance.passwordSet) {
                  page = const face_reg.FaceRegistrationScreen();
                } else {
                  page = const sign_in.SignInScreen();
                }
                break;
              case '/registration_success':
                page = const reg_success.RegistrationSuccessScreen();
                break;
              case '/registration_failed':
                page = const reg_fail.RegistrationFailedScreen();
                break;
              case '/face_preview':
                page = const preview.FaceCapturePreviewScreen();
                break;
              case '/dashboard':
                if (AuthFlowState.instance.canAccessDashboard) {
                  page = const dashboard.DashboardScreen();
                } else {
                  page = const home.HomeScreen();
                }
                break;
              case '/history':
                page = const history.HistoryScreen();
                break;
              case '/face_verification':
                page = const verify.FaceVerificationScreen();
                break;
              case '/attendance_success':
                page = const att_success.AttendanceSuccessScreen();
                break;
              case '/attendance_failed':
                page = const att_fail.AttendanceFailedScreen();
                break;
              case '/location_error':
                page = const loc_error.LocationErrorScreen();
                break;
              case '/profile':
                page = const profile.ProfileScreen();
                break;
              case '/settings':
                page = const settings_screen.SettingsScreen();
                break;
              case '/activate':
                page = const activate.ActivateAccountScreen();
                break;
              case '/qr-precheck':
                page = const qr_precheck.QrPrecheckScreen();
                break;
              case '/qr-scanner':
                page = const qr_scanner.QrScannerScreen();
                break;
              case '/qr-face-verify':
                page = const qr_face_verify.QrFaceVerifyScreen();
                break;
              case '/qr-success':
                page = const qr_success.QrSuccessScreen();
                break;
              case '/qr-timeout':
                final isTimeout = routeSettings.arguments as bool? ?? true;
                page = qr_timeout.QrTimeoutScreen(isTimeout: isTimeout);
                break;
              // ── Auth & password reset flow ───────────────────────────────
              case '/sign_in':
                page = const sign_in.SignInScreen();
                break;
              case '/forgot_password':
                page = const forgot_pw.ForgotPasswordScreen();
                break;
              case '/forgot_password_face_verify':
                page = const forgot_pw_verify.ForgotPasswordFaceVerifyScreen();
                break;
              case '/reset_face_verify':
                page = const reset_face_verify.ResetFaceVerifyScreen();
                break;
              case '/password_reset_face_success':
                page = const pw_reset_success.PasswordResetFaceSuccessScreen();
                break;
              case '/set_new_password':
                page = const set_new_pw.SetNewPasswordScreen();
                break;
              case '/password_updated':
                page = const pw_updated.PasswordUpdatedScreen();
                break;
              case '/password_change_success':
                page = const pw_change_success.PasswordChangeSuccessScreen();
                break;
              case '/face_updated_success':
                page = const face_updated_success.FaceUpdatedSuccessScreen();
                break;
              default:
                page = const splash.SplashScreen();
            }

            if (routeSettings.name == '/activate' ||
                routeSettings.name == '/sign_in' ||
                routeSettings.name == '/forgot_password' ||
                routeSettings.name == '/set_new_password') {
              return AuthPageRoute(page: page);
            }

            return AppStyles.buildPageTransition(page, settings: routeSettings);
          },
        );
      },
    );
  }
}

class AuthPageRoute extends PageRouteBuilder {
  final Widget page;

  AuthPageRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          );
        },
      );
}
