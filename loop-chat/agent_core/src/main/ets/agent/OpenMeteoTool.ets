import { ToolContract } from './ToolContract';
import { weatherContract } from './contracts/WeatherContract';
import { http } from '@kit.NetworkKit';
import util from '@ohos.util';
import { AgentTool } from './AgentTool';

const GEO_URL: string = 'https://geocoding-api.open-meteo.com/v1/search';
const FORECAST_URL: string = 'https://api.open-meteo.com/v1/forecast';
const AIR_URL: string = 'https://air-quality-api.open-meteo.com/v1/air-quality';

const PLACE_NOISE: string[] = [
  '需要穿几件衣服', '要穿几件衣服', '穿几件衣服', '穿什么衣服', '穿什么', '带什么', '怎么办',
  '给点建议', '有什么建议',
  '空气质量怎么样', '空气质量如何', '空气怎么样', '空气质量',
  '今天天气怎么样', '天气怎么样', '天气如何',
  '会不会下雨', '会下雨吗', '下雨吗',
  '冷不冷', '热不热', '多少度', '几度',
  'PM2.5', 'pm2.5', 'AQI', 'aqi',
  '大后天', '后天', '明天',
  '雾霾', '空气', '气温', '温度', '下雨', '降雨', '下雪', '降温', '升温', '天气',
  '帮我查一下', '帮我看一下', '帮我', '查一下', '看一下', '查询一下', '请',
  '现在', '今天', '怎么样', '如何', '好不好'
];

interface QueryRequest {
  query?: string;
  prompt?: string;
  context?: string;
}

interface ParsedQuery {
  query: string;
  context: string;
}

interface GeoResult {
  name?: string;
  latitude?: number;
  longitude?: number;
  country_code?: string;
  timezone?: string;
  admin1?: string;
}

interface GeoPayload {
  results?: GeoResult[];
}

interface WeatherCurrent {
  temperature_2m?: number;
  apparent_temperature?: number;
  relative_humidity_2m?: number;
  weather_code?: number;
  wind_speed_10m?: number;
}

interface WeatherDaily {
  temperature_2m_max?: number[];
  temperature_2m_min?: number[];
  weather_code?: number[];
}

interface WeatherPayload {
  current?: WeatherCurrent;
  daily?: WeatherDaily;
}

interface AirCurrent {
  us_aqi?: number;
  pm2_5?: number;
  pm10?: number;
}

interface AirPayload {
  current?: AirCurrent;
}

interface PlaceHit {
  name: string;
  admin1: string;
  latitude: number;
  longitude: number;
  timezone: string;
}

export class WeatherTool implements AgentTool {
  contract(): ToolContract { return weatherContract('weather'); }

  name(): string {
    return 'weather_search';
  }

  description(): string {
    return 'Current weather only; future dates support today, tomorrow, the day after tomorrow, and three days from now. ' +
      'Input JSON: {"query":"杭州天气","context":"明天"}. Air quality is current only: do not use air_quality for future dates.';
  }

  async run(input: string): Promise<string> {
    const parsed = parseQuery(input);
    const placeName = cleanPlaceQuery(parsed.query);
    const offset = forecastOffset(parsed.query, parsed.context);
    if (placeName.length === 0) {
      return '天气结果\n需要一个城市，例如：深圳天气。';
    }
    try {
      const place = await geocode(placeName);
      if (place === null) {
        return `天气结果\n没有查到「${placeName}」这个城市。`;
      }
      const weather = await fetchWeather(place, offset);
      return formatWeather(place, weather, offset);
    } catch (error) {
      return `天气结果\n天气查询失败：${errorText(error)}`;
    }
  }
}

export class AirQualityTool implements AgentTool {
  contract(): ToolContract { return weatherContract('air'); }

  name(): string {
    return 'air_quality';
  }

  description(): string {
    return 'Current air quality only; future dates are not supported. ' +
      'Input JSON: {"query":"杭州空气质量"}. Do not use this tool for tomorrow or later.';
  }

  async run(input: string): Promise<string> {
    const parsed = parseQuery(input);
    if (dayOffset(parsed.query) > 0 || dayOffset(parsed.context) > 0) {
      return '空气结果\n空气质量工具仅支持当前值，不支持未来日期。';
    }
    const placeName = cleanPlaceQuery(parsed.query);
    if (placeName.length === 0) {
      return '空气结果\n需要一个城市，例如：深圳空气质量。';
    }
    try {
      const place = await geocode(placeName);
      if (place === null) {
        return `空气结果\n没有查到「${placeName}」这个城市。`;
      }
      const air = await fetchAir(place);
      return formatAir(place, air);
    } catch (error) {
      return `空气结果\n空气质量查询失败：${errorText(error)}`;
    }
  }
}

function parseQuery(input: string): ParsedQuery {
  const trimmed = input.trim();
  if (trimmed.startsWith('{')) {
    try {
      const request = JSON.parse(trimmed) as QueryRequest;
      const query = `${request.query ?? request.prompt ?? ''}`.trim();
      const context = `${request.context ?? ''}`.trim();
      if (query.length > 0) {
        return { query: query, context: context };
      }
    } catch (_error) {
      return { query: trimmed, context: '' };
    }
  }
  return { query: trimmed, context: '' };
}

function dayOffset(text: string): number {
  if (text.indexOf('大后天') >= 0) {
    return 3;
  }
  if (text.indexOf('后天') >= 0) {
    return 2;
  }
  if (text.indexOf('明天') >= 0) {
    return 1;
  }
  return 0;
}

function forecastOffset(query: string, context: string): number {
  if (dayOffset(query) > 0 || query.indexOf('今天') >= 0) {
    return dayOffset(query);
  }
  return dayOffset(context);
}

function dayLabel(offset: number): string {
  if (offset === 1) {
    return '明天';
  }
  if (offset === 2) {
    return '后天';
  }
  if (offset === 3) {
    return '大后天';
  }
  return '今天';
}

function cleanPlaceQuery(raw: string): string {
  let text = raw.trim();
  for (let round = 0; round < PLACE_NOISE.length; round++) {
    for (let index = 0; index < PLACE_NOISE.length; index++) {
      const phrase = PLACE_NOISE[index];
      if (text.indexOf(phrase) >= 0) {
        text = text.split(phrase).join('');
      }
    }
  }
  text = trimEdges(stripDecorations(text));
  return text.trim();
}

function trimEdges(text: string): string {
  let value = text.trim();
  for (let round = 0; round < 3; round++) {
    if (value.startsWith('从') || value.startsWith('到') || value.startsWith('的')) {
      value = value.substring(1).trim();
    }
    if (value.endsWith('的') || value.endsWith('和') || value.endsWith('与') || value.endsWith('跟')) {
      value = value.substring(0, value.length - 1).trim();
    }
  }
  return value;
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

async function geocode(name: string): Promise<PlaceHit | null> {
  const url = GEO_URL + '?name=' + encodeURIComponent(name) + '&count=5&language=zh&format=json';
  const body = await requestText(url);
  const payload = JSON.parse(body) as GeoPayload;
  const results = payload.results === undefined ? [] : payload.results;
  let fallback: GeoResult | null = null;
  for (let index = 0; index < results.length; index++) {
    const item = results[index];
    if (!hasCoords(item)) {
      continue;
    }
    if (item.country_code === 'CN') {
      return toPlace(item);
    }
    if (fallback === null) {
      fallback = item;
    }
  }
  return fallback === null ? null : toPlace(fallback);
}

function hasCoords(item: GeoResult): boolean {
  return item.name !== undefined && item.name.length > 0 &&
    item.latitude !== undefined && item.longitude !== undefined;
}

function toPlace(item: GeoResult): PlaceHit {
  const zone = item.timezone === undefined || item.timezone.length === 0 ? 'Asia/Shanghai' : item.timezone;
  const admin1 = item.admin1 === undefined ? '' : item.admin1;
  return {
    name: item.name === undefined ? '' : item.name,
    admin1: admin1,
    latitude: item.latitude === undefined ? 0 : item.latitude,
    longitude: item.longitude === undefined ? 0 : item.longitude,
    timezone: zone
  };
}

async function fetchWeather(place: PlaceHit, offset: number): Promise<WeatherPayload> {
  const days = offset + 1;
  const url = FORECAST_URL +
    '?latitude=' + place.latitude.toString() +
    '&longitude=' + place.longitude.toString() +
    '&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m' +
    '&daily=temperature_2m_max,temperature_2m_min,weather_code' +
    '&timezone=' + encodeURIComponent(place.timezone) +
    '&forecast_days=' + days.toString();
  const body = await requestText(url);
  return JSON.parse(body) as WeatherPayload;
}

async function fetchAir(place: PlaceHit): Promise<AirPayload> {
  const url = AIR_URL +
    '?latitude=' + place.latitude.toString() +
    '&longitude=' + place.longitude.toString() +
    '&current=us_aqi,pm2_5,pm10' +
    '&timezone=' + encodeURIComponent(place.timezone);
  const body = await requestText(url);
  return JSON.parse(body) as AirPayload;
}

async function requestText(url: string): Promise<string> {
  const client = http.createHttp();
  const decoder = util.TextDecoder.create('utf-8');
  try {
    const response = await client.request(url, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'AgentMiniPC/1.1.20' },
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
    return body;
  } finally {
    client.destroy();
  }
}

function placeLabel(place: PlaceHit): string {
  if (place.admin1.length === 0 || place.admin1 === place.name) {
    return place.name;
  }
  return place.name + '（' + place.admin1 + '）';
}

function oneDecimal(value: number): string {
  return value.toFixed(1);
}

function numberAt(values: number[] | undefined, index: number): number | null {
  if (values === undefined || values.length <= index) {
    return null;
  }
  return values[index];
}

function weatherText(code: number): string {
  if (code === 0) {
    return '晴';
  }
  if (code === 1) {
    return '大部晴朗';
  }
  if (code === 2) {
    return '多云';
  }
  if (code === 3) {
    return '阴';
  }
  if (code === 45 || code === 48) {
    return '雾';
  }
  if (code === 51 || code === 53 || code === 55 || code === 56 || code === 57) {
    return '毛毛雨';
  }
  if (code === 61 || code === 80) {
    return '小雨';
  }
  if (code === 63 || code === 81) {
    return '中雨';
  }
  if (code === 65 || code === 82) {
    return '大雨';
  }
  if (code === 66 || code === 67) {
    return '冻雨';
  }
  if (code === 71 || code === 85) {
    return '小雪';
  }
  if (code === 73) {
    return '中雪';
  }
  if (code === 75 || code === 86) {
    return '大雪';
  }
  if (code === 77) {
    return '雪粒';
  }
  if (code === 95) {
    return '雷暴';
  }
  if (code === 96 || code === 99) {
    return '雷暴夹冰雹';
  }
  return '天气代码 ' + code.toString();
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

function aqiText(aqi: number): string {
  if (aqi <= 50) {
    return '优';
  }
  if (aqi <= 100) {
    return '良';
  }
  if (aqi <= 150) {
    return '轻度污染';
  }
  if (aqi <= 200) {
    return '中度污染';
  }
  if (aqi <= 300) {
    return '重度污染';
  }
  return '严重污染';
}

function formatWeather(place: PlaceHit, payload: WeatherPayload, offset: number): string {
  const current = payload.current;
  const daily = payload.daily;
  const high = numberAt(daily === undefined ? undefined : daily.temperature_2m_max, offset);
  const low = numberAt(daily === undefined ? undefined : daily.temperature_2m_min, offset);
  const code = numberAt(daily === undefined ? undefined : daily.weather_code, offset);
  if (offset > 0) {
    if (high === null || low === null || code === null) {
      return '天气结果\n没有这一天的预报。';
    }
    const lines: string[] = [
      '天气结果',
      placeLabel(place),
      dayLabel(offset) + '：' + weatherText(code) + '，' + oneDecimal(low) + '°C 到 ' + oneDecimal(high) + '°C'
    ];
    return lines.join('\n');
  }
  if (current === undefined || current.temperature_2m === undefined || current.weather_code === undefined) {
    return '天气结果\n天气数据不完整。';
  }
  const lines: string[] = ['天气结果', placeLabel(place)];
  let now = '现在：' + weatherText(current.weather_code) + '，' + oneDecimal(current.temperature_2m) + '°C';
  if (current.apparent_temperature !== undefined) {
    now += '，体感 ' + oneDecimal(current.apparent_temperature) + '°C';
  }
  lines.push(now);
  if (current.relative_humidity_2m !== undefined) {
    lines.push('湿度：' + Math.round(current.relative_humidity_2m).toString() + '%');
  }
  if (current.wind_speed_10m !== undefined) {
    lines.push('风速：' + oneDecimal(current.wind_speed_10m) + ' km/h');
  }
  if (high !== null && low !== null) {
    lines.push('今天：' + oneDecimal(low) + '°C 到 ' + oneDecimal(high) + '°C');
  }
  return lines.join('\n');
}

function formatAir(place: PlaceHit, payload: AirPayload): string {
  const current = payload.current;
  if (current === undefined || current.us_aqi === undefined) {
    return '空气结果\n空气质量数据不完整。';
  }
  const aqi = Math.round(current.us_aqi);
  const lines: string[] = [
    '空气结果',
    placeLabel(place),
    '空气质量：' + aqiText(aqi) + '（AQI ' + aqi.toString() + '）'
  ];
  if (current.pm2_5 !== undefined) {
    lines.push('PM2.5：' + oneDecimal(current.pm2_5) + ' μg/m³');
  }
  if (current.pm10 !== undefined) {
    lines.push('PM10：' + oneDecimal(current.pm10) + ' μg/m³');
  }
  return lines.join('\n');
}
