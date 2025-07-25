import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Type definition for a badge
typedef Badge = Map<String, dynamic>;

/// Service for handling gamification logic, including XP, streaks, and badges
class GamificationService {
  // Singleton pattern
  static final GamificationService _instance = GamificationService._internal();
  factory GamificationService() => _instance;
  GamificationService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// List of all badge definitions and their unlock conditions
  final List<Badge> badgeDefinitions = [
    {
      'id': 'first_step',
      'name': 'Headstart',
      'desc': 'You completed your first task!',
      'icon': '🏁',
      // CONDITION:
      // - The user completed their first task
      // - AND they just started using the app (e.g., completedTaskCount == 1)
      'condition': (int completedTaskCount, bool isFirstTimeUser) =>
        completedTaskCount == 1 && isFirstTimeUser,
    },
    {
      'id': 'consistent_mind',
      'name': 'Mushroom Madness',
      'desc': 'Completed all tasks for 3 days in a row',
      'icon': '🍄',
      // CONDITION:
      // - User has 3-day streak
      // - AND completed ALL tasks on each of those 3 days (streakTaskCompletion == 100%)
      'condition': (int streak, int streakCompletionRate) =>
        streak == 3 && streakCompletionRate == 100,
    },
    {
      'id': 'focused_day',
      'name': 'Third Time\'s the Charm',
      'desc': 'Completed all 3 tasks today',
      'icon': '🗓️',
      // CONDITION:
      // - All 3 tasks created today are completed
      'condition': (int todayCount) => todayCount == 3,
    },
    {
      'id': 'morning_start',
      'name': 'Early Bird',
      'desc': 'Completed a task between 06:00–12:00',
      'icon': '🌅',
      // CONDITION:
      // - A task was completed between 06:00–12:00
      'condition': (bool isMorning) => isMorning,
    },
    {
      'id': 'productive_streak',
      'name': 'Tenacious Ten',
      'desc': 'Completed 10 tasks in Total',
      'icon': '🎖️',
      // CONDITION:
      // - User has completed at least 10 tasks total
      'condition': (int completedTaskCount) => completedTaskCount >= 10,
    },
  ];

  /// Call this method when a task is completed to update streak, completedTaskCount, and check for new badges
  Future<void> onTaskCompleted({
    required DateTime completedAt,
    required int totalTasksToday,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;
    final profileRef = _firestore.collection('users').doc(uid).collection('profile').doc('data');
    try {
      // Update completed task count
      await profileRef.set({
        'completedTaskCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error updating completedTaskCount: $e');
    }
    // Update streak
    await _updateStreak(uid);
    // Check and unlock badges
    await _checkAndUnlockBadges(uid, completedAt, totalTasksToday);
  }

  /// Update the user's streak based on the last completion date
  Future<void> _updateStreak(String uid) async {
    final profileRef = _firestore.collection('users').doc(uid).collection('profile').doc('data');
    try {
      final doc = await profileRef.get();
      final data = doc.data() ?? {};
      final lastDate = data['lastTaskDate'] != null ? DateTime.tryParse(data['lastTaskDate']) : null;
      final today = DateTime.now();
      int streak = (data['streak'] ?? 0) as int;
      if (lastDate != null) {
        final diff = today.difference(DateTime(lastDate.year, lastDate.month, lastDate.day)).inDays;
        if (diff == 1) {
          streak += 1;
        } else if (diff > 1) {
          streak = 1;
        }
      } else {
        streak = 1;
      }
      await profileRef.set({
        'streak': streak,
        'lastTaskDate': today.toIso8601String(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error updating streak: $e');
    }
  }

  /// Check and unlock badges after streak update
  Future<void> _checkAndUnlockBadges(String uid, DateTime completedAt, int totalTasksToday) async {
    final profileRef = _firestore.collection('users').doc(uid).collection('profile').doc('data');
    final badgesRef = _firestore.collection('users').doc(uid).collection('badges');
    try {
      final profileSnap = await profileRef.get();
      final profile = profileSnap.data() ?? {};
      final completedTaskCount = (profile['completedTaskCount'] ?? 0) as int;
      final streak = (profile['streak'] ?? 0) as int;
      final isMorning = completedAt.hour >= 6 && completedAt.hour < 12;
      // Fallbacks for new badge condition params
      final isFirstTimeUser = (profile['createdAt'] != null && completedTaskCount == 1);
      // TODO: Calculate streakCompletionRate for last 3 days (requires more data structure)
      final streakCompletionRate = 100; // Placeholder: assume 100% for now
      for (final badge in badgeDefinitions) {
        final badgeId = badge['id'] as String;
        try {
          final badgeDoc = await badgesRef.doc(badgeId).get();
          if (badgeDoc.exists) {
            debugPrint('Badge $badgeId already unlocked, skipping.');
            continue; // Already unlocked
          }
          bool unlocked = false;
          try {
            if (badge['condition'] == null) {
              debugPrint('Badge $badgeId has null condition, skipping.');
              continue;
            }
            // Call the correct condition signature for each badge
            switch (badgeId) {
              case 'first_step':
                unlocked = badge['condition'](completedTaskCount, isFirstTimeUser);
                break;
              case 'consistent_mind':
                unlocked = badge['condition'](streak, streakCompletionRate);
                break;
              case 'focused_day':
                unlocked = badge['condition'](totalTasksToday);
                break;
              case 'morning_start':
                unlocked = badge['condition'](isMorning);
                break;
              case 'productive_streak':
                unlocked = badge['condition'](completedTaskCount);
                break;
              default:
                unlocked = false;
            }
          } catch (e) {
            debugPrint('Error evaluating badge $badgeId: $e');
            continue;
          }
          if (unlocked) {
            try {
              await badgesRef.doc(badgeId).set({
                'name': badge['name'],
                'desc': badge['desc'],
                'icon': badge['icon'],
                'unlockedAt': FieldValue.serverTimestamp(),
              });
              debugPrint('Badge $badgeId unlocked!');
            } catch (e) {
              debugPrint('Error writing badge $badgeId: $e');
            }
          } else {
            debugPrint('Badge $badgeId not unlocked (condition false).');
          }
        } catch (e) {
          debugPrint('Error in badge loop for $badgeId: $e');
        }
      }
    } catch (e) {
      debugPrint('Error checking/unlocking badges: $e');
    }
  }

  /// Fetch the user's profile data (streak, completed task count)
  Future<Map<String, dynamic>> fetchProfile() async {
    final user = _auth.currentUser;
    if (user == null) return {};
    final profileRef = _firestore.collection('users').doc(user.uid).collection('profile').doc('data');
    try {
      final doc = await profileRef.get();
      return doc.data() ?? {};
    } catch (e) {
      debugPrint('Error fetching profile: $e');
      return {};
    }
  }

  /// Fetch all badges (both unlocked and locked) for the user
  Future<List<Badge>> fetchBadges() async {
    final user = _auth.currentUser;
    if (user == null) return [];
    final badgesRef = _firestore.collection('users').doc(user.uid).collection('badges');
    try {
      final unlocked = await badgesRef.get();
      final unlockedIds = unlocked.docs.map((d) => d.id).toSet();
      return badgeDefinitions.map((badge) {
        final isUnlocked = unlockedIds.contains(badge['id']);
        final unlockedDocList = unlocked.docs.where((d) => d.id == badge['id']).toList();
        final unlockedData = unlockedDocList.isNotEmpty ? unlockedDocList.first : null;
        return {
          ...badge,
          'unlocked': isUnlocked,
          'unlockedAt': unlockedData != null ? unlockedData.data()['unlockedAt'] : null,
        };
      }).toList();
    } catch (e) {
      debugPrint('Error fetching badges: $e');
      return badgeDefinitions.map((b) => {...b, 'unlocked': false}).toList();
    }
  }
} 