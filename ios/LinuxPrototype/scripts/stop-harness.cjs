// Throwaway guest shutdown helper: stop only the official CLI process.
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const isHarness = pid => {
    try {
        return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').some(arg => arg.endsWith('/@deepseek-ai/dsh/lib/bin.js'));
    } catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ESRCH') return false;
        throw error;
    }
};
const targets = fs.readdirSync('/proc').filter(pid => /^\d+$/.test(pid) && Number(pid) !== process.pid && isHarness(pid));
for (const pid of targets) {
    try { process.kill(Number(pid), 'SIGTERM'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
}
const deadline = performance.now() + 60000;
const timer = setInterval(() => {
    if (targets.some(isHarness)) {
        if (performance.now() >= deadline) {
            clearInterval(timer);
            console.log('HARNESS_STOP_TIMEOUT');
            process.exitCode = 1;
        }
        return;
    }
    clearInterval(timer);
    execFileSync('/bin/busybox', ['sync'], {timeout: 60000});
    console.log('HARNESS_STOPPED');
}, 1000);
