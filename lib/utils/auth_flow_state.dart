class AuthFlowState {
  AuthFlowState._();
  static final instance = AuthFlowState._();

  bool isFirstTimeUser = false;
  bool passwordSet = false;
  bool faceRegistered = false;

  bool get canAccessDashboard => passwordSet && faceRegistered;

  void reset() {
    passwordSet = false;
    faceRegistered = false;
  }
}
