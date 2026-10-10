const fs=require('node:fs');
const compiler=process.argv[2] || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript';
const ts=require(compiler);
function transpileSource(source){
 return ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
}
function transpile(file){return transpileSource(fs.readFileSync(file,'utf8'));}
module.exports={transpile,transpileSource};
