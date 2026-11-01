import 'package:flutter/material.dart';

import 'permission_service.dart';

class PermissionInfo {
  const PermissionInfo(this.icon, this.title, this.why);
  final IconData icon;
  final String title;
  final String why;
}

const permissionInfo = <AppPermission, PermissionInfo>{
  AppPermission.notifications: PermissionInfo(
      Icons.notifications_active_rounded, 'Notifications', 'Get alerts when hosts you follow go live and when you get new messages.'),
  AppPermission.camera: PermissionInfo(
      Icons.videocam_rounded, 'Camera', 'Go live with video, join video seats and take photos for chat.'),
  AppPermission.microphone: PermissionInfo(
      Icons.mic_rounded, 'Microphone', 'Speak on voice seats, in PK battles and in live rooms.'),
  AppPermission.media: PermissionInfo(
      Icons.photo_library_rounded, 'Photos & media', 'Send pictures in chat and choose your profile photo.'),
};
