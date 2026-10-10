/* Offline strict noEmit check of actual ETS, renamed only to .ts in a temporary tree. */
const fs=require('node:fs'), path=require('node:path'), os=require('node:os');
const compiler=process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript';
const ts=require(compiler);
const sdk=process.env.OHOS_API_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/api';
const root=path.resolve(__dirname,'../src/main/ets');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'loop-support-check-'));
const files=['model/SessionBackedModel','model/OpenAiCompatibleModel','model/TextCompletionResponse','modelscope/ModelScopeConfig','modelscope/ModelScopeDirectClient','modelscope/ModelScopeClient','agent/LocalUtilityTools','agent/AgentTool','file/BoundedWorkspaceSearch','file/SandboxWorkspace','aiphone/runtime/DynamicToolTypes','agent/ToolContract',...fs.readdirSync(path.join(root,'agent/contracts')).filter(n=>n.endsWith('.ets')).map(n=>'agent/contracts/'+n.slice(0,-4))];
function write(name,text){const dest=path.join(temp,name);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,text);}
try {
 for(const file of files)write(file+'.ts',fs.readFileSync(path.join(root,file+'.ets'),'utf8'));
 const stubs={
 'agent/ConversationContext.ts':'export interface ConversationContext {} export interface ChatMessage {role: string; content: string;}',
 'model/LocalModel.ts':'export interface LocalModel {complete(prompt: string, conversation?: import("../agent/ConversationContext").ConversationContext): Promise<string>}',
 'model/LlmProvider.ts':'export interface LlmProvider {model:string;apiKey:string;customParametersJson:string;isConfigured():boolean;chatCompletionsUrl():string;}',
 'skill/SkillLog.ts':'export declare function skillLogInfo(s:string):void; export declare function skillLogWarn(s:string):void; export declare function skillLogInfoChunks(a:string,b:string):void;',
 'skill/SkillSnapshot.ts':'export interface SkillSnapshot {} export declare function buildSkillsSection(snapshot:SkillSnapshot|null):string;',
 'aiphone/runtime/AiphoneLogger.ts':'export declare function aiLogInfo(s:string):void;',
 'aiphone/runtime/A2uiTypes.ts':'export interface A2uiAction {} export interface A2uiLabelValueData {}',
 'aiphone/runtime/GenericMcpClient.ts':'import {DynamicToolRegistration,DynamicPreflightResult,DynamicGenericToolResult} from "./DynamicToolTypes"; export declare class GenericMcpClient {preflight(r:DynamicToolRegistration,c:string):Promise<DynamicPreflightResult>;callTool(r:DynamicToolRegistration,c:string,args:Object):Promise<DynamicGenericToolResult>;}',
 'platform.d.ts':'declare module "@kit.AbilityKit" {export namespace common {interface UIAbilityContext {resourceManager:{getRawFileContent(path:string):Promise<Uint8Array|ArrayBuffer>}}}} declare module "@kit.PerformanceAnalysisKit" {export const hilog:{info(domain:number,tag:string,fmt:string,...args:(string|number)[]):void};}'
 };
 for(const [name,text] of Object.entries(stubs))write(name,text);
 const paths={};for(const name of ['file.fs','util','url','net.http'])paths['@ohos.'+name]=[path.join(sdk,'@ohos.'+name+'.d.ts')];
 const options={strict:true,useUnknownInCatchVariables:false,noEmit:true,skipLibCheck:true,target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,moduleResolution:ts.ModuleResolutionKind.NodeJs,baseUrl:temp,paths};
 const program=ts.createProgram([...files.map(f=>path.join(temp,f+'.ts')),path.join(temp,'platform.d.ts')],options);
 const diagnostics=ts.getPreEmitDiagnostics(program);
 const errors=diagnostics.filter(d=>d.category===ts.DiagnosticCategory.Error);
 if(diagnostics.length)console.log(ts.formatDiagnosticsWithColorAndContext(diagnostics,{getCanonicalFileName:x=>x,getCurrentDirectory:()=>temp,getNewLine:()=> '\n'}));
 if(errors.length)process.exitCode=1;
 else console.log('PASS strict noEmit: '+files.length+' actual ETS files; actual installed fs/util/url/http SDK declarations; TypeScript '+ts.version+'; '+diagnostics.length+' SDK warnings, zero errors.');
} finally {fs.rmSync(temp,{recursive:true,force:true});}
