# Bazel cache miss example

A minimal Bazel 9 project that shows how an action stamping the current timestamp into generated code defeats the cache.

The build has a single `genrule` action, `//:build_info`, that generates the shell code `build_info.sh` with the project version and the build timestamp.

## How stamping causes cache misses

Bazel looks up an action in the cache by its action key, a digest of the command line, the environment, and the digests of all input files.
The same action key always has to produce the same outputs, otherwise a cached result can never be reused.

`//:build_info` sets `stamp = 1`, which adds `bazel-out/volatile-status.txt` to its inputs.
Bazel writes a fresh `BUILD_TIMESTAMP` into that file for every build, so the action key of `//:build_info` changes with every build.
The generated `build_info.sh` changes as well, which in a real project changes the action key of every action that consumes it.

```starlark
genrule(
    name = "build_info",
    srcs = ["VERSION"],
    outs = ["build_info.sh"],
    cmd = ("{ echo \"BUILD_VERSION=$$(cat $(location VERSION))\"; " +
           "echo \"BUILD_TIMESTAMP=$$(grep '^BUILD_TIMESTAMP ' bazel-out/volatile-status.txt | cut -d ' ' -f 2)\"; } > $@"),
    stamp = 1,
)
```

The local action cache ignores changes to `volatile-status.txt`, so an incremental build on the same machine looks fine.
The problem appears whenever the output base is fresh, for example on CI runners, on another developer's machine, or after `bazel clean`.
There, every build misses the disk or remote cache and reruns `//:build_info`.

`.bazelrc` enables a disk cache in `~/.cache/bazel-cache-miss-example`, which survives `bazel clean` and simulates a shared remote cache.

## Prerequisites

Install [Bazelisk](https://github.com/bazelbuild/bazelisk).
It reads `.bazelversion` and downloads the pinned Bazel version on first use.
The commands below call `bazelisk`. If Bazelisk is installed as `bazel`, use that name instead.

Watch the `INFO: N processes: ...` line near the end of each build's output.
On Linux the strategy is `linux-sandbox` or `processwrapper-sandbox` instead of `darwin-sandbox`, and output paths start with `bazel-out/k8-fastbuild` instead of `bazel-out/darwin_arm64-fastbuild`.

## Step 1: Build with an empty disk cache

```shell
rm -rf ~/.cache/bazel-cache-miss-example
bazelisk clean
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_1.pb
```

The action executes because the cache is empty.

```
INFO: 2 processes: 1 internal, 1 darwin-sandbox.
```

The `--execution_log_binary_file` flag writes every executed action, with its inputs, outputs and action key, to `/tmp/exec_log_1.pb`.

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
BUILD_TIMESTAMP=1794157443
```

## Step 2: Rebuild after a clean

```shell
bazelisk clean
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_2.pb
```

Nothing in the workspace changed, yet the action executes again instead of being served from the disk cache.

```
INFO: 2 processes: 1 internal, 1 darwin-sandbox.
```

The generated code now contains a different timestamp.

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
BUILD_TIMESTAMP=1794157444
```

Repeat this step as often as you like, the result is the same every time.

## Step 3: Compare the execution logs

The binary execution logs need to be converted to text with the parser that ships with the Bazel source code.
Check out the Bazel version used by this project and build the parser.

```shell
git clone --depth 1 --branch "$(cat .bazelversion)" https://github.com/bazelbuild/bazel.git /tmp/bazel
(cd /tmp/bazel && bazelisk build //src/tools/execlog:parser)
```

Convert both logs in one invocation, so the parser orders the actions of the second log to match the first one.

```shell
/tmp/bazel/bazel-bin/src/tools/execlog/parser \
  --log_path=/tmp/exec_log_1.pb --log_path=/tmp/exec_log_2.pb \
  --output_path=/tmp/exec_log_1.txt --output_path=/tmp/exec_log_2.txt
diff -u /tmp/exec_log_1.txt /tmp/exec_log_2.txt
```

Ignore the differences under `metrics`, they only record timings.
The first differing input of `//:build_info` is `volatile-status.txt`, which is the root cause.
It leads to a different output `build_info.sh` and a different action key.

```diff
 inputs {
   path: "bazel-out/volatile-status.txt"
   digest {
-    hash: "2ebb4154bf4de28822bf596ac97289b3cbc9445b4cc9e66dd57d34d6dd1963b1"
+    hash: "02eb15002ee93191da82b3039e411a25a84d08a066c08dd652372ae3367abb7d"
     size_bytes: 67
     hash_function_name: "SHA-256"
   }
 actual_outputs {
   path: "bazel-out/darwin_arm64-fastbuild/bin/build_info.sh"
   digest {
-    hash: "34dcc97a3a45589625754bbd41b3d657c8a502e2b95e655ac9a22d0a00f7ab82"
+    hash: "f23db4ed4287c340a32092867086fc350d677fc8edd115354423de89660374ca"
     size_bytes: 47
     hash_function_name: "SHA-256"
   }
 remote_cacheable: true
 target_label: "//:build_info"
 digest {
-  hash: "2abd84aa72de795c42a6f3737108dc70003debbb0eaedda1691cae72b099332b"
+  hash: "3568bd8349eb4c494d021220a9ddeac5fa82d95633fe4ca2ed2a719a1f2f1b2a"
   size_bytes: 146
   hash_function_name: "SHA256"
 }
```


`scripts/diff-exec-logs.sh` condenses the diff to the paths and action keys whose digests differ.

```shell
./scripts/diff-exec-logs.sh /tmp/exec_log_1.txt /tmp/exec_log_2.txt
```

```
action key of //:build_info
bazel-out/darwin_arm64-fastbuild/bin/build_info.sh
bazel-out/volatile-status.txt
```

## Step 4: Apply the fix and build

Generated code should only depend on declared inputs.
`fix.patch` removes `stamp = 1` and the timestamp from `//:build_info`, so the generated code only depends on the checked-in `VERSION` file.

```diff
 genrule(
     name = "build_info",
     srcs = ["VERSION"],
     outs = ["build_info.sh"],
-    cmd = ("{ echo \"BUILD_VERSION=$$(cat $(location VERSION))\"; " +
-           "echo \"BUILD_TIMESTAMP=$$(grep '^BUILD_TIMESTAMP ' bazel-out/volatile-status.txt | cut -d ' ' -f 2)\"; } > $@"),
-    stamp = 1,
+    cmd = "echo \"BUILD_VERSION=$$(cat $(location VERSION))\" > $@",
 )
```

```shell
git apply fix.patch
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_3.pb
```

The action executes once more because its action key changed with the fix.

```
INFO: 2 processes: 1 internal, 1 darwin-sandbox.
```

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
```

If a build needs to record information like a timestamp or a commit, apply it to the final artifact in a step at the end of the build that is cheap to rerun, not to code that other actions consume.

## Step 5: Rebuild the fixed project after a clean

```shell
bazelisk clean
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_4.pb
```

This time the action is served from the disk cache and nothing executes.

```
INFO: 2 processes: 1 disk cache hit, 1 internal.
```

## Step 6: Compare the execution logs of the fixed project

```shell
/tmp/bazel/bazel-bin/src/tools/execlog/parser \
  --log_path=/tmp/exec_log_3.pb --log_path=/tmp/exec_log_4.pb \
  --output_path=/tmp/exec_log_3.txt --output_path=/tmp/exec_log_4.txt
diff -u /tmp/exec_log_3.txt /tmp/exec_log_4.txt
```

All digests are identical.
The only differences are the runner, which is now the disk cache, and the metrics.

```diff
-runner: "darwin-sandbox"
+runner: "disk cache hit"
+cache_hit: true
```

`scripts/diff-exec-logs.sh` prints nothing.

```shell
./scripts/diff-exec-logs.sh /tmp/exec_log_3.txt /tmp/exec_log_4.txt
```

Run `git checkout -- BUILD.bazel` to restore the original project.

## GitHub Actions

The workflow in `.github/workflows/cache-miss-demo.yml` runs every step above as a separate workflow step on `ubuntu-latest` and `macos-latest`.
After each build, `scripts/verify-build.sh` fails the step if the number of executed actions or disk cache hits does not match.
The comparison steps fail if `scripts/diff-exec-logs.sh` does not report the expected differing digests.
