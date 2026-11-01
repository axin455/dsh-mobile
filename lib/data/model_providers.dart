import 'package:flutter/foundation.dart';

/// 一个可选模型：`value` 是发给 API 的模型名，`label` 是给人看的名字。
@immutable
class ModelOption {
  const ModelOption(this.value, this.label);

  final String value;
  final String label;
}

/// 一个「填 API Key 就能直接对话」的供应商预设。
///
/// 所有预设都走 OpenAI 兼容的 `/chat/completions`，差异只在 Base URL 与模型名。
/// 地址与模型名都允许在页面上修改，预设只是省去手填。
@immutable
class ModelProvider {
  const ModelProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.models = const <ModelOption>[],
    this.note = '',
  });

  final String id;
  final String name;

  /// 不含 `/chat/completions` 的地址前缀。
  final String baseUrl;
  final String model;
  final List<ModelOption> models;
  final String note;

  ModelProvider copyWith({String? baseUrl, String? model}) => ModelProvider(
    id: id,
    name: name,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    models: models,
    note: note,
  );
}

/// 主流供应商（2026-10 官方模型 ID）。模型名仍可在页面上手填覆盖。
const kModelProviders = <ModelProvider>[
  ModelProvider(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-v4-flash',
    models: [
      ModelOption('deepseek-v4-flash', 'DeepSeek V4.1 Flash'),
      ModelOption('deepseek-v4-pro', 'DeepSeek V4.1 Pro'),
    ],
    note: 'DeepSeek 官方 OpenAI 兼容接口，按 Key 用量单独计费。',
  ),
  ModelProvider(
    id: 'zhipu',
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-5.3',
    models: [
      ModelOption('glm-5.3', 'GLM-5.3'),
      ModelOption('glm-5.3-flash', 'GLM-5.3 Flash'),
      ModelOption('glm-5-turbo', 'GLM-5 Turbo'),
    ],
    note: '智谱开放平台的 OpenAI 兼容接口。',
  ),
  ModelProvider(
    id: 'kimi',
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    model: 'kimi-k3.1-pro',
    models: [
      ModelOption('kimi-k3.1-pro', 'Kimi K3.1 Pro'),
      ModelOption('kimi-k3', 'Kimi K3'),
    ],
    note: '月之暗面 Moonshot 开放平台。',
  ),
  ModelProvider(
    id: 'minimax',
    name: 'MiniMax',
    baseUrl: 'https://api.minimax.chat/v1',
    model: 'MiniMax-M3.1-Flash',
    models: [
      ModelOption('MiniMax-M3.1-Flash', 'MiniMax M3.1 Flash'),
      ModelOption('MiniMax-M3', 'MiniMax M3'),
    ],
    note: 'MiniMax 开放平台的 OpenAI 兼容接口。',
  ),
  ModelProvider(
    id: 'mimo',
    name: '小米 MiMo',
    baseUrl: 'https://api.mimo.xiaomi.com/v1',
    model: 'mimo-v2.6-pro',
    models: [
      ModelOption('mimo-v2.6-pro', 'MiMo V2.6 Pro'),
      ModelOption('mimo-v2.6-flash', 'MiMo V2.6 Flash'),
      ModelOption('mimo-v2.6-pro-ultraspeed', 'MiMo V2.6 Pro UltraSpeed'),
    ],
    note: '小米 MiMo 开放平台；地址与模型名以官方文档为准，可自行修改。',
  ),
  ModelProvider(
    id: 'qwen',
    name: '通义千问',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen3.8-max',
    models: [
      ModelOption('qwen3.8-max', 'Qwen 3.8 Max'),
      ModelOption('qwen3-max', 'Qwen 3 Max'),
      ModelOption('qwen-plus', 'Qwen Plus'),
    ],
    note: '阿里云百炼兼容模式，兼容 OpenAI 协议。',
  ),
  ModelProvider(
    id: 'doubao',
    name: '豆包',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-seed-2-1-pro-260628',
    models: [
      ModelOption('doubao-seed-2-1-pro-260628', '豆包 Seed 2.1 Pro'),
    ],
    note: '火山方舟 OpenAI 兼容接口，模型名请以控制台接入点为准。',
  ),
  ModelProvider(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-5.6',
    models: [
      ModelOption('gpt-5.6', 'GPT-5.6'),
      ModelOption('gpt-5.5', 'GPT-5.5'),
    ],
    note: 'OpenAI 官方接口，需要可用的 API Key。',
  ),
  ModelProvider(
    id: 'custom',
    name: '自定义',
    baseUrl: '',
    model: '',
    note: '任何 OpenAI 兼容服务：填名称、Base URL 与模型名即可。',
  ),
];

ModelProvider? providerById(String id) {
  for (final provider in kModelProviders) {
    if (provider.id == id) return provider;
  }
  return null;
}
