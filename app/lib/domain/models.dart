import 'package:cloud_firestore/cloud_firestore.dart';

import 'release.dart';

/// Grupa osób, którym udostępniam aplikacje (np. "Rodzina").
/// Firestore: groups/{id} - name, ownerId, members[], memberEmails{uid: e-mail}, trustedSigners[]
class StoreGroup {
  const StoreGroup({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.members,
    required this.memberEmails,
    this.trustedSigners = const [],
    this.autoAdd = false,
  });

  final String id;
  final String name;
  final String ownerId;
  final List<String> members;
  final Map<String, String> memberEmails;

  /// Odciski SHA-256 kluczy, którymi mogą być podpisane instalowane APK
  /// (oprócz klucza samego sklepu).
  final List<String> trustedSigners;

  /// Nowe wydania dopisują się do tej grupy same (włączane wyraźnie: sklep auto tak).
  final bool autoAdd;

  bool isOwner(String uid) => ownerId == uid;
  String get ownerEmail => memberEmails[ownerId] ?? '';

  factory StoreGroup.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return StoreGroup(
      id: doc.id,
      name: (d['name'] as String?) ?? '',
      ownerId: (d['ownerId'] as String?) ?? '',
      members: ((d['members'] as List?) ?? const []).whereType<String>().toList(),
      memberEmails: d['memberEmails'] is Map
          ? (d['memberEmails'] as Map).map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''))
          : const {},
      trustedSigners: ((d['trustedSigners'] as List?) ?? const []).whereType<String>().toList(),
      autoAdd: d['autoAdd'] == true,
    );
  }
}

/// Aplikacja w katalogu grupy. Firestore: groups/{gid}/apps/{id}
class StoreApp {
  const StoreApp({
    this.id = '',
    this.groupId = '',
    required this.name,
    required this.packageName,
    required this.repo,
    this.description = '',
    this.tagPrefix = 'v',
    this.assetName = '',
    this.iconUrl = '',
    this.order = 100,
    this.prerelease = false,
    this.hidden = false,
    this.latest,
  });

  final String id;
  final String groupId;
  final String name;
  final String description;
  final String packageName;

  /// "owner/repo" na GitHubie
  final String repo;

  /// Prefiks tagów wydań tej aplikacji: "v" (repo jednej aplikacji) albo np. "zakupy-v" (monorepo)
  final String tagPrefix;

  /// Nazwa pliku APK w wydaniu bez ".apk" (pusta = pierwszy plik .apk)
  final String assetName;
  final String iconUrl;
  final int order;

  /// Pokazuj wersje testowe (pre-release) - np. w grupie "Testerzy"
  final bool prerelease;

  /// Ukryta przed członkami grupy (widzi ją tylko właściciel)
  final bool hidden;

  /// Najnowsze wydanie zapisane przez CI (etap 2); null = pytamy GitHub
  final AppRelease? latest;

  String get repoUrl => 'https://github.com/$repo';

  factory StoreApp.fromDoc(String groupId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final latestRaw = d['latest'];
    AppRelease? latest;
    if (latestRaw is Map) {
      final m = latestRaw.map((k, v) => MapEntry(k.toString(), v is Timestamp ? v.toDate() : v));
      latest = AppRelease.fromJson(m);
    }
    return StoreApp(
      id: doc.id,
      groupId: groupId,
      name: (d['name'] as String?) ?? '',
      description: (d['description'] as String?) ?? '',
      packageName: (d['packageName'] as String?) ?? '',
      repo: (d['repo'] as String?) ?? '',
      tagPrefix: (d['tagPrefix'] as String?) ?? 'v',
      assetName: (d['assetName'] as String?) ?? '',
      iconUrl: (d['iconUrl'] as String?) ?? '',
      order: (d['order'] as num?)?.toInt() ?? 100,
      prerelease: d['prerelease'] == true,
      hidden: d['hidden'] == true,
      latest: latest,
    );
  }

  /// Pola edytowane przez właściciela (bez `latest`, które zapisuje CI).
  Map<String, dynamic> toEditableJson() => {
        'name': name.trim(),
        'description': description.trim(),
        'packageName': packageName.trim(),
        'repo': repo.trim(),
        'tagPrefix': tagPrefix.trim().isEmpty ? 'v' : tagPrefix.trim(),
        'assetName': assetName.trim(),
        'iconUrl': iconUrl.trim(),
        'order': order,
        'prerelease': prerelease,
        'hidden': hidden,
      };

  StoreApp copyWith({String? groupId, bool? prerelease, AppRelease? latest}) => StoreApp(
        id: id,
        groupId: groupId ?? this.groupId,
        name: name,
        description: description,
        packageName: packageName,
        repo: repo,
        tagPrefix: tagPrefix,
        assetName: assetName,
        iconUrl: iconUrl,
        order: order,
        prerelease: prerelease ?? this.prerelease,
        hidden: hidden,
        latest: latest ?? this.latest,
      );
}

/// Aplikacja zainstalowana na telefonie (z PackageManagera).
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    this.signerSha256,
  });

  final String packageName;
  final String versionName;
  final int versionCode;
  final String? signerSha256;

  static InstalledApp? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return InstalledApp(
      packageName: (raw['packageName'] ?? '').toString(),
      versionName: (raw['versionName'] ?? '').toString(),
      versionCode: (raw['versionCode'] as num?)?.toInt() ?? 0,
      signerSha256: raw['signerSha256']?.toString(),
    );
  }
}

/// Zaproszenie do grupy. Firestore: invites/{kod}
class Invite {
  const Invite({
    required this.code,
    required this.groupId,
    required this.groupName,
    required this.createdBy,
    required this.expiresAt,
  });

  final String code;
  final String groupId;
  final String groupName;
  final String createdBy;
  final DateTime expiresAt;

  bool get isValid => expiresAt.isAfter(DateTime.now());

  factory Invite.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final exp = d['expiresAt'];
    return Invite(
      code: doc.id,
      groupId: (d['groupId'] as String?) ?? '',
      groupName: (d['groupName'] as String?) ?? '',
      createdBy: (d['createdBy'] as String?) ?? '',
      expiresAt: exp is Timestamp ? exp.toDate() : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Wpis "kto ma którą wersję". Firestore: groups/{gid}/installs/{uid}_{pakiet}
class InstallReport {
  const InstallReport({
    required this.uid,
    required this.email,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    this.updatedAt,
  });

  final String uid;
  final String email;
  final String packageName;
  final String versionName;
  final int versionCode;
  final DateTime? updatedAt;

  factory InstallReport.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final t = d['updatedAt'];
    return InstallReport(
      uid: (d['uid'] as String?) ?? '',
      email: (d['email'] as String?) ?? '',
      packageName: (d['packageName'] as String?) ?? '',
      versionName: (d['versionName'] as String?) ?? '',
      versionCode: (d['versionCode'] as num?)?.toInt() ?? 0,
      updatedAt: t is Timestamp ? t.toDate() : null,
    );
  }
}

/// Konto z książki adresowej `emails` (wspólnej z Zakupami i Powrotem).
class UserAccount {
  const UserAccount({required this.uid, required this.email});

  final String uid;
  final String email;
}
