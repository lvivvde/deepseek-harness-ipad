// The first-release runtime pins this official API; the plugin itself stays editable.
import {defineTool} from '/opt/harness/node_modules/@deepseek-ai/dsh-tools/lib/index.js';
export const name = 'ipad-hello';
export const inject = ['tools'];
export function apply(ctx) {
  ctx.tools.register(defineTool({
    name: 'ipad_hello',
    description: 'Return a greeting from this user-authored iPad plugin.',
    parameters: {},
    output: {schema: {type: 'string'}, render: (_args, value) => [{type: 'text', text: value}]},
    execute: async () => '你好，来自 iPad 自制插件！',
    presentCall: () => ({card: 'generic', kind: 'read', title: 'iPad Hello'})
  }));
}
