import {execFileSync} from 'node:child_process';
import * as fs from 'node:fs';

describe('macOS installed PHP version comparison', () => {
  const functions = fs
    .readFileSync('src/scripts/darwin.sh', 'utf8')
    .split('# Variables')[0];

  it.each([
    ['8.7.0-dev', '8.7.0', 'Found'],
    ['8.6.0-dev', '8.6.0', 'Found'],
    ['8.7.0-dev', '8.7.0-dev', 'Found'],
    ['8.5.9', '8.5.9', 'Found'],
    ['8.5.9', '8.5.11', 'Upgraded'],
    ['8.6.0RC1', '8.6.0', 'Upgraded'],
    ['8.7.0-dev', '8.7.1', 'Upgraded']
  ])('handles runtime %s with formula %s', (runtime, formula, expected) => {
    // Exercise setup_php's real selection path while isolating system writes
    // and the configuration stage from this version-comparison regression.
    const output = execFileSync(
      'bash',
      [
        '-c',
        `${functions}
version="$REQUESTED"
debug=release ts=nts old_versions='^5\\.[3-5]$'
src=/unused RUNNER_TOOL_CACHE=/unused tool_path_dir=/unused tick=ok cross=error
step_log() { :; }
check_pre_installed() { :; }
get_brewed_php() { echo "$RUNTIME"; }
php_semver() { echo "$RUNTIME"; }
brew() { test "$1" = info || exit 2; echo "$FORMULA"; }
jq() { cat; }
add_php() { printf '%s\n' "$1" >&3; }
php-config() { :; }
sed() { echo /unused; }
sudo() { :; }
php_ini_path() { echo /unused; }
get_scan_dir() { echo /unused; }
php_extra_version() { :; }
configure_php() { :; }
link_opcache() { :; }
set_output() { :; }
add_log() { printf '%s\n' "$*"; }
setup_php 3>&1
`
      ],
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          REQUESTED: runtime.split('.').slice(0, 2).join('.'),
          RUNTIME: runtime,
          FORMULA: formula
        }
      }
    );
    expect(output).toContain(`${expected} PHP ${runtime}`);
    if (expected === 'Upgraded') expect(output).toContain('upgrade\n');
    else expect(output).not.toContain('upgrade\n');
  });
});
