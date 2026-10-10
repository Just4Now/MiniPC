import { LocalModel } from '../model/LocalModel';
import { TaskGraph } from './TaskCoordinator';
import { TASK_CONTRACT_PROMPT } from './TaskContract';
import { parseCorePlan } from './ReActCore';
// Planner, executor and aggregator may be backed by different model devices.
export async function planTaskGraph(task: string, model: LocalModel, toolDescriptions: string, registered: (name: string) => boolean): Promise<TaskGraph> {
  const prompt = TASK_CONTRACT_PROMPT + '\nPlanning phase ONLY: return Plan JSON, no Action or Final. Add nodes: [{"id":"n1","goalIds":["g1"],"dependsOn":[]}]. ' +
    'Assign each goal to exactly one node. Put independent work in separate nodes; add dependencies when one result is needed to answer another goal. ' +
    'Do not choose devices or execution permissions; the coordinator owns those. No cycles.\nTools:\n' + toolDescriptions + '\nUser task:\n' + task;
  const response = await model.complete(prompt);
  const plan = parseCorePlan(response, registered);
  if (plan.error.length || plan.calls.length || /(?:^|\n)\s*Final\s*:/i.test(response) || !(plan.goals ?? []).length || !(plan.nodes ?? []).length) { throw new Error(plan.error || 'Planner did not return a complete task graph'); }
  return { goals: plan.goals ?? [], nodes: plan.nodes ?? [] };
}
