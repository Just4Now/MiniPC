import { ToolContract } from './ToolContract';
import { mapContract } from './contracts/MapContract';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import util from '@ohos.util';
import { AgentTool } from './AgentTool';

const RESULT_LIMIT: number = 5;
const CONFIG_RAWFILE: string = 'aiphone_provider_config.json';
const AMAP_URL: string = 'https://restapi.amap.com/v3/place/text';
const CITY_HINTS: string[] = ['北京', '上海', '深圳', '广州', '杭州', '南京', '成都', '武汉', '西安', '重庆', '天津', '苏州'];

const PLACE_NOISE: string[] = [
  '离我最近的', '离我最近',
  '在哪里', '在哪', '在什么地方', '什么位置', '的位置',
  '怎么走', '怎么去',
  '导航到', '导航去', '导航',
  '地图上', '地图',
  '路线',
  '帮我查一下', '帮我找一下', '帮我查询', '帮我搜索', '帮我',
  '查一下', '查询一下', '找一下', '搜索一下', '请帮我', '请',
  '一下'
];

interface QueryRequest {
  query?: string;
  prompt?: string;
}

interface ProviderConfigJson {
  AMAP_KEY?: string;
  amapKey?: string;
}

interface AmapPoi {
  name?: string;
  address?: string | string[];
  location?: string;
  pname?: string;
  cityname?: string;
  adname?: string;
}

interface AmapPayload {
  status?: string;
  info?: string;
  pois?: AmapPoi[];
}

interface PlaceHit {
  name: string;
  address: string;
  location: string;
}

export class MapSearchTool implements AgentTool {
  contract(): ToolContract { return mapContract(); }

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  name(): string {
    return 'map_search';
  }

  description(): string {
    return 'Searches places on Amap. Input JSON: {"query":"北京华为"}. Returns name and address.';
  }

  async run(input: string): Promise<string> {
    const raw = parseQuery(input);
    if (/^离我|^我附近|^离我最近|^我最近/.test(raw)) {
      return '地图结果\n没有手机位置，不能按距离找最近的地点。请提供城市或具体地点作为搜索范围。';
    }
    const query = cleanPlaceQuery(raw);
    if (query.length === 0) {
      return '地图结果\n需要一个地点，例如：深圳北站在哪里。';
    }
    const key = await this.readAmapKey();
    if (key.length === 0) {
      return '地图结果\n还没有配置高德 Key。';
    }
    try {
      const places = await searchAmap(query, key);
      if (places.length === 0) {
        return `地图结果\n没有查到「${query}」。`;
      }
      return formatPlaces(query, places);
    } catch (error) {
      return `地图结果\n地图查询失败：${errorText(error)}`;
    }
  }

  private async readAmapKey(): Promise<string> {
    try {
      const raw = await this.context.resourceManager.getRawFileContent(CONFIG_RAWFILE);
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw.buffer);
      const parsed = JSON.parse(decoder.decodeToString(bytes)) as ProviderConfigJson;
      const key = parsed.AMAP_KEY ?? parsed.amapKey ?? '';
      return key.trim();
    } catch (_error) {
      return '';
    }
  }
}

function parseQuery(input: string): string {
  const trimmed = input.trim();
  if (trimmed.startsWith('{')) {
    try {
      const request = JSON.parse(trimmed) as QueryRequest;
      const query = `${request.query ?? request.prompt ?? ''}`.trim();
      if (query.length > 0) {
        return query;
      }
    } catch (_error) {
      return trimmed;
    }
  }
  return trimmed;
}

function cleanPlaceQuery(raw: string): string {
  let text = raw.trim();
  text = text.replace(/附近的/g, ' ').replace(/附近/g, ' ');
  for (let round = 0; round < PLACE_NOISE.length; round++) {
    for (let index = 0; index < PLACE_NOISE.length; index++) {
      const phrase = PLACE_NOISE[index];
      if (text.indexOf(phrase) >= 0) {
        text = text.split(phrase).join('');
      }
    }
  }
  text = stripDecorations(text);
  if (text.startsWith('从') || text.startsWith('到') || text.startsWith('的')) {
    text = text.substring(1);
  }
  return text.trim();
}

function stripDecorations(text: string): string {
  const drop = '？?，,。.!！、\t\n';
  let out = '';
  for (let index = 0; index < text.length; index++) {
    const ch = text.charAt(index);
    if (drop.indexOf(ch) < 0) {
      out += ch;
    }
  }
  return out.trim();
}

function textOf(value: string | string[] | undefined): string {
  if (value === undefined) {
    return '';
  }
  if (typeof value === 'string') {
    return value.trim();
  }
  return value.join(' ').trim();
}

function joinParts(parts: string[]): string {
  let out = '';
  for (let index = 0; index < parts.length; index++) {
    if (parts[index].length > 0) {
      out += parts[index];
    }
  }
  return out;
}

function splitCity(query: string): string[] {
  for (let index = 0; index < CITY_HINTS.length; index++) {
    const city = CITY_HINTS[index];
    if (query.startsWith(city) && query.length > city.length) {
      return [city, query.substring(city.length)];
    }
  }
  return ['', query];
}

async function searchAmap(query: string, key: string): Promise<PlaceHit[]> {
  const parts = splitCity(query);
  let url = AMAP_URL + '?key=' + encodeURIComponent(key) +
    '&keywords=' + encodeURIComponent(parts[1].length > 0 ? parts[1] : query) +
    '&offset=' + RESULT_LIMIT.toString() + '&page=1&extensions=base';
  if (parts[0].length > 0) {
    url += '&city=' + encodeURIComponent(parts[0]);
  }
  const client = http.createHttp();
  const decoder = util.TextDecoder.create('utf-8');
  try {
    const response = await client.request(url, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'AgentMiniPC/1.1.23' },
      usingProtocol: http.HttpProtocol.HTTP1_1,
      connectTimeout: 12000,
      readTimeout: 12000
    });
    let body = '';
    if (typeof response.result === 'string') {
      body = response.result;
    } else {
      body = decoder.decodeToString(new Uint8Array(response.result as ArrayBuffer));
    }
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error('HTTP ' + response.responseCode.toString());
    }
    const payload = JSON.parse(body) as AmapPayload;
    if (payload.status !== '1') {
      throw new Error(payload.info ?? '高德没有返回地点');
    }
    return uniquePlaces(payload.pois === undefined ? [] : payload.pois);
  } finally {
    client.destroy();
  }
}

function uniquePlaces(pois: AmapPoi[]): PlaceHit[] {
  const places: PlaceHit[] = [];
  const seen: string[] = [];
  for (let index = 0; index < pois.length && places.length < RESULT_LIMIT; index++) {
    const poi = pois[index];
    const name = textOf(poi.name);
    if (name.length === 0) {
      continue;
    }
    const address = joinParts([textOf(poi.pname), textOf(poi.cityname), textOf(poi.adname), textOf(poi.address)]);
    const key = name + '|' + address;
    if (seen.indexOf(key) >= 0) {
      continue;
    }
    seen.push(key);
    places.push({ name: name, address: address, location: textOf(poi.location) });
  }
  return places;
}

function bestPlace(query: string, places: PlaceHit[]): PlaceHit {
  for (let index = 0; index < places.length; index++) {
    const name = places[index].name;
    if (name.indexOf(query) >= 0 || query.indexOf(name) >= 0) {
      return places[index];
    }
  }
  return places[0];
}

function formatPlaces(query: string, places: PlaceHit[]): string {
  const place = bestPlace(query, places);
  const lines: string[] = ['地图结果', `已查到「${query}」。`, `1. ${place.name}`];
  if (place.address.length > 0) {
    lines.push(`地址：${place.address}`);
  }
  if (place.location.length > 0) {
    lines.push(`坐标：${place.location}`);
  }
  const extra = places.length - 1;
  if (extra > 0) {
    lines.push(`另有 ${extra.toString()} 个相关地点。`);
  }
  return lines.join('\n');
}

interface ErrorFields {
  code?: number;
  message?: string;
}

function errorText(error: Object): string {
  if (error === null || error === undefined) {
    return '未知错误';
  }
  if (error instanceof Error) {
    return error.message;
  }
  const fields = error as ErrorFields;
  const message = fields.message === undefined ? '' : fields.message;
  const code = fields.code === undefined ? '' : fields.code.toString();
  if (code.length > 0 && message.length > 0) {
    return code + ' ' + message;
  }
  if (message.length > 0) {
    return message;
  }
  if (code.length > 0) {
    return code;
  }
  return '未知错误';
}
