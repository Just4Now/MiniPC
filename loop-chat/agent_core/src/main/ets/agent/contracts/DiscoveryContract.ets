import { schemaProperties } from '../ToolContract';
import { ToolContract, ValueSchema } from '../ToolContract';
// Multi-stage providers own their execution argument name and error envelope.
export function discoveryContract(name: string, executeField: string): ToolContract {
    const properties: Record<string, ValueSchema> = schemaProperties(["operation", "useCase", "arguments"], [{ type: 'string', enum: ['search', 'execute'] } as ValueSchema, { type: 'string', minLength: 1 } as ValueSchema, { type: 'object' } as ValueSchema]);
    properties[executeField] = { type: 'string', minLength: 1 } as ValueSchema;
    return { version: '1', inputFormat: 'json', inputSchema: { type: 'object', properties: properties, required: ['operation'],
            anyOf: [{ type: 'object', required: ['operation', 'useCase'], properties: schemaProperties(["operation"], [{ type: 'string', enum: ['search'] } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema, { type: 'object', required: ['operation', executeField], properties: schemaProperties(["operation"], [{ type: 'string', enum: ['execute'] } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema] } as ValueSchema,
        outputSchema: { type: 'string' } as ValueSchema, finalization: 'synthesis',
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' => !text.trim().length ? 'empty' : text.toLowerCase().startsWith(name.toLowerCase() + ' 参数错误：') ? 'failed' : 'success' };
}
