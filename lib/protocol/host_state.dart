/// 电脑端 DSH 下发的账号资料、API 凭据与模型目录。
library;

class HostBalance {
  const HostBalance({required this.currency, required this.balance});

  final String currency;
  final double balance;

  String get label {
    final symbol = currency == 'CNY'
        ? '¥'
        : currency == 'USD'
        ? '\$'
        : '$currency ';
    return '$symbol${balance.toStringAsFixed(2)}';
  }

  static HostBalance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final currency = (raw['currency'] ?? '').toString();
    final value = raw['balance'];
    final amount = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? 0;
    if (currency.isEmpty) return null;
    return HostBalance(currency: currency, balance: amount);
  }

  static List<HostBalance> listOf(Object? raw) {
    if (raw is! List) return const <HostBalance>[];
    return raw
        .map(HostBalance.fromJson)
        .whereType<HostBalance>()
        .toList(growable: false);
  }
}

/// DSH 账号（DeepSeek 账号平台），由电脑端 `account/getProfile` 提供。
class HostAccount {
  const HostAccount({
    required this.signedIn,
    this.name = '',
    this.contact = '',
    this.avatarUrl = '',
    this.balances = const <HostBalance>[],
    this.bonusWallets = const <HostBalance>[],
  });

  final bool signedIn;
  final String name;
  final String contact;
  final String avatarUrl;
  final List<HostBalance> balances;
  final List<HostBalance> bonusWallets;

  HostBalance? get primaryBalance =>
      balances.isEmpty ? null : balances.first;

  /// 头像地址是 DeepSeek 官方 CDN；只在 HTTPS 下使用。
  Uri? get avatarUri {
    final uri = Uri.tryParse(avatarUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  factory HostAccount.fromFrame(Map<String, dynamic> frame) {
    final profile = frame['profile'] is Map
        ? (frame['profile'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return HostAccount(
      signedIn: frame['signedIn'] == true,
      name: (profile['name'] ?? '').toString(),
      contact: (profile['contact'] ?? '').toString(),
      avatarUrl: (profile['avatarUrl'] ?? '').toString(),
      balances: HostBalance.listOf(frame['balances']),
      bonusWallets: HostBalance.listOf(frame['bonusWallets']),
    );
  }
}

/// 一台电脑上的一个可选模型（provider + model 二元组）。
class HostModelOption {
  const HostModelOption({
    required this.provider,
    required this.providerName,
    required this.model,
    required this.name,
    this.description = '',
  });

  final String provider;
  final String providerName;
  final String model;
  final String name;
  final String description;

  String get label => name.trim().isEmpty ? model : name.trim();

  bool matches(String? providerId, String? modelId) =>
      provider == providerId && model == modelId;

  /// `session/modelCatalog.groups` → 扁平的可选项列表。
  static List<HostModelOption> listFromGroups(Object? groups) {
    if (groups is! List) return const <HostModelOption>[];
    final options = <HostModelOption>[];
    for (final group in groups) {
      if (group is! Map) continue;
      final provider = (group['id'] ?? '').toString();
      if (provider.isEmpty) continue;
      final providerName = (group['name'] ?? provider).toString();
      final models = group['models'];
      if (models is! List) continue;
      for (final model in models) {
        if (model is! Map) continue;
        final id = (model['id'] ?? '').toString();
        if (id.isEmpty) continue;
        options.add(
          HostModelOption(
            provider: provider,
            providerName: providerName,
            model: id,
            name: (model['name'] ?? id).toString(),
            description: (model['description'] ?? '').toString(),
          ),
        );
      }
    }
    return options;
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'providerName': providerName,
    'model': model,
    'name': name,
    'description': description,
  };

  /// 本地缓存恢复：字段缺失时跳过，避免旧数据把整个列表读坏。
  static List<HostModelOption> listFromCache(Object? raw) {
    if (raw is! List) return const <HostModelOption>[];
    final options = <HostModelOption>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final provider = (item['provider'] ?? '').toString();
      final model = (item['model'] ?? '').toString();
      if (provider.isEmpty || model.isEmpty) continue;
      options.add(
        HostModelOption(
          provider: provider,
          providerName: (item['providerName'] ?? provider).toString(),
          model: model,
          name: (item['name'] ?? model).toString(),
          description: (item['description'] ?? '').toString(),
        ),
      );
    }
    return options;
  }
}

/// 电脑端下发的供应商凭据。Key 只进 Keystore，不写普通配置。
class SyncedCredential {
  const SyncedCredential({
    required this.provider,
    required this.displayName,
    required this.baseUrl,
    required this.apiKey,
    required this.last4,
    this.api = 'openai-completions',
    this.models = const <String>[],
    this.defaultModel = '',
  });

  final String provider;
  final String displayName;
  final String baseUrl;
  final String apiKey;
  final String last4;
  final String api;
  final List<String> models;
  final String defaultModel;

  static SyncedCredential? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final provider = (raw['provider'] ?? '').toString();
    final apiKey = (raw['apiKey'] ?? '').toString();
    final baseUrl = (raw['baseUrl'] ?? '').toString();
    if (provider.isEmpty || apiKey.isEmpty || baseUrl.isEmpty) return null;
    final models = raw['models'] is List
        ? (raw['models'] as List)
              .whereType<Map>()
              .map((item) => (item['id'] ?? '').toString())
              .where((id) => id.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return SyncedCredential(
      provider: provider,
      displayName: (raw['displayName'] ?? provider).toString(),
      baseUrl: baseUrl,
      apiKey: apiKey,
      last4: (raw['last4'] ?? '').toString().isEmpty
          ? apiKey.substring(apiKey.length >= 4 ? apiKey.length - 4 : 0)
          : raw['last4'].toString(),
      api: (raw['api'] ?? 'openai-completions').toString(),
      models: models,
      defaultModel: (raw['defaultModel'] ?? '').toString(),
    );
  }

  static List<SyncedCredential> listFromFrame(Map<String, dynamic> frame) {
    final raw = frame['credentials'];
    if (raw is! List) return const <SyncedCredential>[];
    return raw
        .map(SyncedCredential.fromJson)
        .whereType<SyncedCredential>()
        .toList(growable: false);
  }
}
