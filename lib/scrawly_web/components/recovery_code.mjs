// Copy / download helpers for RecoveryCodePanel. The code only ever lives in
// the page's state and here, on its way to the clipboard or a local file.

function fallbackCopy(code) {
  const area = document.createElement("textarea");
  area.value = code;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();

  try {
    document.execCommand("copy");
  } catch (_error) {
    // Nothing else to try; the code is still on screen.
  }

  document.body.removeChild(area);
}

export function copyRecoveryCode(code) {
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(code).catch(() => fallbackCopy(code));
  } else {
    fallbackCopy(code);
  }
}

export function downloadRecoveryCode(code) {
  const text =
    "Scrawly recovery code\n\n" +
    code +
    "\n\nUse it with \"forgot password?\" to set a new password.\n" +
    "It works once: you get a new code each time you use it.\n";

  const url = URL.createObjectURL(new Blob([text], {type: "text/plain"}));
  const link = document.createElement("a");
  link.href = url;
  link.download = "scrawly-recovery-code.txt";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
