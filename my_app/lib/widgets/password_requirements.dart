import 'package:flutter/material.dart';

class PasswordRequirements extends StatelessWidget {
  final String password;

  const PasswordRequirements({super.key, required this.password});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Password requirements:',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 8),
        _buildRequirement('At least 10 characters', password.length >= 10),
        _buildRequirement('One uppercase letter (A-Z)', RegExp(r'[A-Z]').hasMatch(password)),
        _buildRequirement('One lowercase letter (a-z)', RegExp(r'[a-z]').hasMatch(password)),
        _buildRequirement('One number (0-9)', RegExp(r'\d').hasMatch(password)),
        _buildRequirement('One special character (!@#\$%&*)', RegExp(r'[^A-Za-z0-9]').hasMatch(password)),
      ],
    );
  }

  Widget _buildRequirement(String text, bool met) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: met ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: met ? Colors.green.shade700 : Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Returns true if all complexity requirements are met.
bool passwordMeetsRequirements(String password) {
  return password.length >= 10 &&
      RegExp(r'[A-Z]').hasMatch(password) &&
      RegExp(r'[a-z]').hasMatch(password) &&
      RegExp(r'\d').hasMatch(password) &&
      RegExp(r'[^A-Za-z0-9]').hasMatch(password);
}
