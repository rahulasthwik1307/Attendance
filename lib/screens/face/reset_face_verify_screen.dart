import 'package:flutter/material.dart';

class ResetFaceVerifyScreen extends StatefulWidget {
  const ResetFaceVerifyScreen({super.key});

  @override
  State<ResetFaceVerifyScreen> createState() => _ResetFaceVerifyScreenState();
}

class _ResetFaceVerifyScreenState extends State<ResetFaceVerifyScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).pushReplacementNamed(
        '/face_verification',
        arguments: 'face_reset',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
