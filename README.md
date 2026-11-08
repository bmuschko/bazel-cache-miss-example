# Bazel cache miss example

A minimal Bazel 9 project that shows how an action stamping the current timestamp into generated code defeats the cache.

The build has two `genrule` actions.
`//:build_info` generates the shell code `build_info.sh` with the project version and the build timestamp.
`//:app` bundles the generated code with `src/main.sh` into the executable script `app.sh`.

## How stamping causes cache misses

Bazel looks up an action in the cache by its action key, a digest of the command line, the environment, and the digests of all input files.
The same action key always has to produce the same outputs, otherwise a cached result can never be reused.

`//:build_info` sets `stamp = 1`, which adds `bazel-out/volatile-status.txt` to its inputs.
Bazel writes a fresh `BUILD_TIMESTAMP` into that file for every build, so the action key of `//:build_info` changes with every build.
The generated `build_info.sh` changes as well, which changes the action key of every action that consumes it, here `//:app`.

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
There, every build misses the disk or remote cache and reruns `//:build_info` and everything downstream of it.

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

Both actions execute because the cache is empty.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

The `--execution_log_binary_file` flag writes every executed action, with its inputs, outputs and action key, to `/tmp/exec_log_1.pb`.

```shell
bazel-bin/app.sh
```

```
Hello from version 1.4.0, built at 1794153950
```

## Step 2: Rebuild after a clean

```shell
bazelisk clean
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_2.pb
```

Nothing in the workspace changed, yet both actions execute again instead of being served from the disk cache.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

The script now reports a different timestamp.

```shell
bazel-bin/app.sh
```

```
Hello from version 1.4.0, built at 1794153964
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
-    hash: "fbc184ddc3439f546c84be34a31a017f6dffef0140bd864b9910d0d1807019ef"
+    hash: "d74f94dd0a835c037ba2f8d52ba580ee27f79c7363c26b1ca11bba0988b9dc51"
     size_bytes: 67
     hash_function_name: "SHA-256"
   }
 actual_outputs {
   path: "bazel-out/darwin_arm64-fastbuild/bin/build_info.sh"
   digest {
-    hash: "d1321cf11f267819b142638b9ffb30bb5b661d972d850e0126456053de1f2038"
+    hash: "0252414801ace8dd37915a5fc92f0ed91597ae397983f51bacda6905d69fce1a"
     size_bytes: 47
     hash_function_name: "SHA-256"
   }
 remote_cacheable: true
 target_label: "//:build_info"
 digest {
-  hash: "3c05efa356f99bc1ddd034500098dc95e577df7b3d261e6ecb495aa4ad282c87"
+  hash: "2c7529fcd3cb9c524964a1d15711412d3e5e1d2461912c4ea44a4f1d06ae10e9"
   size_bytes: 146
   hash_function_name: "SHA256"
 }
```

`//:app` then sees the changed `build_info.sh` as an input, so its action key and output change too.

```diff
 inputs {
   path: "bazel-out/darwin_arm64-fastbuild/bin/build_info.sh"
   digest {
-    hash: "d1321cf11f267819b142638b9ffb30bb5b661d972d850e0126456053de1f2038"
+    hash: "0252414801ace8dd37915a5fc92f0ed91597ae397983f51bacda6905d69fce1a"
     size_bytes: 47
     hash_function_name: "SHA-256"
   }
```

`scripts/diff-exec-logs.sh` condenses the diff to the paths and action keys whose digests differ.

```shell
./scripts/diff-exec-logs.sh /tmp/exec_log_1.txt /tmp/exec_log_2.txt
```

```
action key of //:app
action key of //:build_info
bazel-out/darwin_arm64-fastbuild/bin/app.sh
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

Both actions execute once more because their action keys changed with the fix.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

```shell
bazel-bin/app.sh
```

```
Hello from version 1.4.0
```

If a build needs to record information like a timestamp or a commit, apply it to the final artifact in a step at the end of the build that is cheap to rerun, not to code that other actions consume.

## Step 5: Rebuild the fixed project after a clean

```shell
bazelisk clean
bazelisk build //... --execution_log_binary_file=/tmp/exec_log_4.pb
```

This time both actions are served from the disk cache and nothing executes.

```
INFO: 3 processes: 2 disk cache hit, 1 internal.
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

Run `git checkout -- BUILD.bazel src/main.sh` to restore the original project.

## GitHub Actions

The workflow in `.github/workflows/cache-miss-demo.yml` runs every step above as a separate workflow step on `ubuntu-latest` and `macos-latest`.
After each build, `scripts/verify-build.sh` fails the step if the number of executed actions or disk cache hits does not match.
The comparison steps fail if `scripts/diff-exec-logs.sh` does not report the expected differing digests.
