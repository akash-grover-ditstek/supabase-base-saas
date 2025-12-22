// Edge Runtime main service: routes /<function-name>/... to that function.
//
// Each function runs in its own isolated user worker created from
// /home/deno/functions/<name>/index.js. The worker receives this process's
// environment (Supabase URL/keys and Stripe secrets). Shared modules
// (`_shared`) and unknown names are not routable.

const FUNCTIONS_DIR = "/home/deno/functions";
const FUNCTION_NAME = /^[a-z0-9][a-z0-9-]*$/;

const json = (body, status) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function exists(path) {
  try {
    return (await Deno.stat(path)).isFile;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  const name = new URL(req.url).pathname.split("/")[1] ?? "";

  if (name === "_health") return json({ status: "ok" }, 200);

  const entrypoint = `${FUNCTIONS_DIR}/${name}/index.js`;
  if (!FUNCTION_NAME.test(name) || !(await exists(entrypoint))) {
    return json({ error: { code: "not_found", message: "Function not found" } }, 404);
  }

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `${FUNCTIONS_DIR}/${name}`,
      maybeEntrypoint: `file://${entrypoint}`,
      memoryLimitMb: 150,
      workerTimeoutMs: 60_000,
      noModuleCache: false,
      envVars: Object.entries(Deno.env.toObject()),
      forceCreate: false,
    });
    return await worker.fetch(req);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", scope: "main", function: name, message: String(err?.message ?? err) }));
    return json({ error: { code: "internal_error", message: "An unexpected error occurred" } }, 500);
  }
});
