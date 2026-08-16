export type RunStatus = "success" | "failed" | "in-progress";

export interface WorkflowRun {
  name: string;
  workflow: string;
  branch: string;
  branchGroup: string;
  event: string;
  commit: string;
  duration: string;
  updated: string;
  status: RunStatus;
}

export const workflowRuns: WorkflowRun[] = [
  {
    name: "CI",
    workflow: "Ruby 3.4 · ubuntu-latest",
    branch: "main",
    branchGroup: "main",
    event: "push",
    commit: "9f2a1c7",
    duration: "2m 14s",
    updated: "12 min ago",
    status: "success"
  },
  {
    name: "Security audit",
    workflow: "Dependency review",
    branch: "main",
    branchGroup: "main",
    event: "schedule",
    commit: "8d3b0f1",
    duration: "1m 08s",
    updated: "34 min ago",
    status: "success"
  },
  {
    name: "CI",
    workflow: "Ruby 3.2 · ubuntu-latest",
    branch: "release/0.3",
    branchGroup: "release",
    event: "push",
    commit: "7c1e4a9",
    duration: "3m 02s",
    updated: "1 hr ago",
    status: "failed"
  },
  {
    name: "Release audit",
    workflow: "Safety contract",
    branch: "main",
    branchGroup: "main",
    event: "workflow_dispatch",
    commit: "6a91d2e",
    duration: "4m 41s",
    updated: "2 hrs ago",
    status: "success"
  },
  {
    name: "CI",
    workflow: "Ruby 4.0 · ubuntu-latest",
    branch: "feature/flow",
    branchGroup: "feature",
    event: "pull_request",
    commit: "5e7b3c2",
    duration: "—",
    updated: "Running now",
    status: "in-progress"
  },
  {
    name: "Lint",
    workflow: "RuboCop",
    branch: "main",
    branchGroup: "main",
    event: "push",
    commit: "4f8a1b6",
    duration: "—",
    updated: "Running now",
    status: "in-progress"
  }
];
