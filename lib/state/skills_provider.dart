import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../skills/local/local_skill.dart';
import '../skills/local/skill_store.dart';

@immutable
class SkillsState {
  const SkillsState({
    this.skills = const <LocalSkill>[],
    this.loading = false,
    this.error,
  });

  final List<LocalSkill> skills;
  final bool loading;
  final String? error;

  List<LocalSkill> get enabledSkills =>
      skills.where((item) => item.enabled).toList(growable: false);

  SkillsState copyWith({
    List<LocalSkill>? skills,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => SkillsState(
    skills: skills ?? this.skills,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

final skillStoreProvider = Provider<SkillStore>((ref) => SkillStore());

final skillsProvider = NotifierProvider<SkillsNotifier, SkillsState>(
  SkillsNotifier.new,
);

class SkillsNotifier extends Notifier<SkillsState> {
  @override
  SkillsState build() {
    unawaited(Future.microtask(refresh));
    return const SkillsState(loading: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final skills = await ref.read(skillStoreProvider).scan();
      state = SkillsState(skills: skills);
    } catch (error) {
      state = state.copyWith(loading: false, error: '读取技能失败：$error');
    }
  }

  Future<LocalSkill> importFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final skill = await ref
        .read(skillStoreProvider)
        .importFile(fileName: fileName, bytes: bytes);
    state = SkillsState(skills: [skill, ...state.skills]);
    return skill;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await ref.read(skillStoreProvider).setEnabled(id, enabled);
    state = state.copyWith(
      skills: [
        for (final skill in state.skills)
          if (skill.id == id) skill.copyWith(enabled: enabled) else skill,
      ],
    );
  }

  Future<void> remove(String id) async {
    await ref.read(skillStoreProvider).remove(id);
    state = state.copyWith(
      skills: state.skills
          .where((skill) => skill.id != id)
          .toList(growable: false),
    );
  }
}
