/* Repeat the controlled-provider regressions and strict TypeScript checks.
 * Platform declarations are stubbed here; a separate SDK build is still required. */
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const suites=['react-runner.test.cjs','parallel-runner.test.cjs','support-models.test.cjs','integration-contract.test.cjs',
 'integration-lifecycle.test.cjs','index-lifecycle.test.cjs','inference-budget.test.cjs',
 'tool-contracts.test.cjs','react-core.typecheck.cjs','support-models.typecheck.cjs','integration-contract.typecheck.cjs'];
let failed=0;
for(const suite of suites){
 console.log('\nRunning '+suite);
 const result=spawnSync(process.execPath,[path.join(__dirname,suite)],{stdio:'inherit',env:process.env});
 if(result.error){console.error(result.error);failed++;}
 else if(result.status!==0)failed++;
}
console.log('\n'+(suites.length-failed)+'/'+suites.length+' suites passed; SDK compilation and device tests are separate.');
if(failed)process.exitCode=1;
