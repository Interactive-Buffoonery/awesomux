import { pathToFileURL } from "node:url";

const commandScopes = new Map([
  ["/ci", "all"],
  ["/ci all", "all"],
  ["/ci unit", "unit"],
  ["/ci adapter", "adapter"],
  ["/ci system", "system"],
]);

export function parseNativeCICommand(body) {
  return commandScopes.get(body) ?? null;
}

export function authorizeNativeCIRequest(request) {
  const {
    actor,
    maintainerLogins,
    repository,
    issueIsPullRequest,
    pullRequest,
  } = request;

  if (
    !Array.isArray(maintainerLogins) ||
    !maintainerLogins.every((login) => typeof login === "string")
  ) {
    throw new Error("maintainer allowlist must be an array of logins");
  }
  if (!maintainerLogins.includes(actor)) {
    throw new Error("native CI requires a maintainer command author");
  }
  if (!issueIsPullRequest) {
    throw new Error("native CI requires a pull request comment");
  }
  if (pullRequest?.state !== "open") {
    throw new Error("native CI requires an open pull request");
  }
  if (pullRequest.draft !== false) {
    throw new Error("native CI does not run for a draft pull request");
  }
  if (pullRequest.head?.repo?.full_name !== repository) {
    throw new Error("native CI requires a same repository pull request");
  }
  if (!/^[0-9a-f]{40}$/.test(pullRequest.head.sha ?? "")) {
    throw new Error("native CI requires a 40-character lowercase head SHA");
  }

  return {
    headSHA: pullRequest.head.sha,
    prNumber: pullRequest.number,
  };
}

async function main() {
  const mode = process.argv[2];

  if (mode === "parse") {
    const scope = parseNativeCICommand(process.argv[3]);
    if (scope === null) {
      process.exitCode = 2;
      return;
    }
    process.stdout.write(`${scope}\n`);
    return;
  }

  if (mode === "authorize") {
    let input = "";
    for await (const chunk of process.stdin) {
      input += chunk;
    }
    const result = authorizeNativeCIRequest(JSON.parse(input));
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }

  throw new Error("usage: native-ci-request.mjs <parse BODY|authorize>");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
