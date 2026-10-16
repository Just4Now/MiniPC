export interface CreateSessionResult {
  session: number;
  error: number;
}

export interface SubmitRequestResult {
  request: number;
  error: number;
}

export declare function llmCreateSession(attributes: string): CreateSessionResult;
export declare function llmDestroySession(session: number): number;
export declare function llmSubmitRequest(
  session: number,
  request: string,
  callback: (response: string) => void
): SubmitRequestResult;
export declare function llmAbortRequest(session: number, request: number): number;
export declare function llmEnableCollaboration(info: string): number;
export declare function llmDisableCollaboration(): number;
export declare function llmIsCollaborationSupported(): boolean;
