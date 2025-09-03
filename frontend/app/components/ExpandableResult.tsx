"use client";

import { useState } from "react";

export default function ExpandableResult({ result }: { result: unknown }) {
  const [expanded, setExpanded] = useState(false);

  const isString = typeof result === "string";
  const isArray = Array.isArray(result);
  const isObject = !!result && typeof result === "object" && !isArray;

  const truncate = (str: string, n = 200) => (str.length > n ? str.slice(0, n) + "…" : str);

  let typeLabel = "Unknown";
  let summaryLine = "";

  if (isString) {
    typeLabel = "String";
    summaryLine = truncate(result as string);
  } else if (isArray) {
    const arr = result as unknown[];
    typeLabel = `Array(${arr.length})`;
    if (arr.length > 0) {
      const first = arr[0] as unknown;
      if (first !== null && typeof first === "object" && !Array.isArray(first)) {
        const keys = Object.keys(first as Record<string, unknown>);
        const keysPreview = keys.slice(0, 3).join(", ");
        summaryLine = `{ ${keysPreview}${keys.length > 3 ? ", …" : ""} }`;
      } else {
        summaryLine = `First item: ${String(first).slice(0, 80)}`;
      }
    }
  } else if (isObject) {
    const obj = result as Record<string, unknown>;
    const keys = Object.keys(obj);
    typeLabel = "Object";
    const keysPreview = keys.slice(0, 3).join(", ");
    summaryLine = `{ ${keysPreview}${keys.length > 3 ? ", …" : ""} } • ${keys.length} keys`;
  } else if (result === null) {
    typeLabel = "Null";
    summaryLine = "null";
  } else {
    typeLabel = typeof result;
    summaryLine = String(result);
  }

  return (
    <div className="mt-1">
      {!expanded ? (
        <div className="border rounded bg-blue-50/60">
          <div className="flex items-center justify-between px-2 py-1">
            <span className="text-[10px] uppercase tracking-wide text-blue-700">
              {typeLabel}
            </span>
            <button
              className="text-[11px] text-blue-700 hover:text-blue-900 underline"
              onClick={() => setExpanded(true)}
            >
              Show details ▸
            </button>
          </div>
          {summaryLine && (
            <div className="px-2 pb-2">
              <pre className="text-xs overflow-auto bg-blue-50 p-2 rounded whitespace-pre-wrap break-words">
                {summaryLine}
              </pre>
            </div>
          )}
        </div>
      ) : (
        <div>
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-medium text-gray-600">Response</h3>
            <button
              className="text-[11px] text-blue-700 hover:text-blue-900 underline"
              onClick={() => setExpanded(false)}
            >
              Hide details ◂
            </button>
          </div>
          <pre className="mt-1 text-xs overflow-auto bg-blue-50 p-2 rounded">
            {isString
              ? (result as string)
              : (() => {
                  try {
                    return JSON.stringify(result, null, 2);
                  } catch {
                    return "<unable to serialize result>";
                  }
                })()}
          </pre>
        </div>
      )}
    </div>
  );
}
