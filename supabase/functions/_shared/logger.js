// Minimal structured logger. One JSON object per line keeps logs searchable
// in the Supabase dashboard. Never pass secrets or full payloads as fields.

export function createLogger(scope, sink = console) {
  const write = (level, message, fields = {}) => {
    const line = JSON.stringify({ level, scope, message, ...fields, ts: new Date().toISOString() });
    if (level === "error") sink.error(line);
    else if (level === "warn") sink.warn(line);
    else sink.log(line);
  };
  return {
    info: (message, fields) => write("info", message, fields),
    warn: (message, fields) => write("warn", message, fields),
    error: (message, fields) => write("error", message, fields),
  };
}

/** A logger that discards everything (used by tests). */
export const silentLogger = { info() {}, warn() {}, error() {} };
