# vLLM-Ascend 构建失败排查：CANN 内置算子撞名 与 构建目录残留

适用对象：`afd_build_and_compile.sh`（vllm-ascend 固定 `8d4409d6`，并给三个算子改过名）。

结论先给：**这两类失败都不是源码逻辑问题，也不是环境坏了，是"名字"和"残留状态"问题。**
看到下面两类报错，不要重装 CANN、不要换镜像、不要怀疑 torch/torch_npu。

---

## 一、撞名：OPC 报 "op store" ABI 不一致

### 症状

失败发生在 `bash csrc/build_aclnn.sh ...` 阶段（`pip install -e .` 的输出里），
报错形态只有两种：

```
[op_compile_info_check.py:50][check_op_optional_paramtype]
    Op[type=CausalConv1d] invalid input nums[8], which should be equal to input nums[12] in op store.
```

```
[op_compilation.py:344][__single_op_compile] Exception occured, 'NoneType' object is not subscriptable
  File ".../opc_tool/op_info_parser.py", line 280, in __compare_and_warn_del_attr
    if op_attr[CompileParam.NAME] == attr[CompileParam.NAME]:
TypeError: 'NoneType' object is not subscriptable
```

再往上看会有一行汇总：

```
[ERROR] record_compile_error_info: Op[<算子名>] of index[0] compile failed, kernelName: None.
```

### 根因

CANN 9.2 **自带**一套 ops_transformer 内置算子：

```
/usr/local/Ascend/cann-9.2.0/opp/built-in/op_impl/ai_core/tbe/kernel/<soc>/ops_transformer/<算子>_apt/
例：.../ascend950/ops_transformer/causal_conv1d_apt/CausalConv1d_*.json|.o
```

编译自定义算子时，OPC 会拿本仓库的算子定义去和 op store 里的**同名**内置算子比对；
名字一样但参数/属性 ABI 不同，就直接失败。

**内置算子删不掉**（那是 toolkit 的一部分，动整个环境都会坏），
所以只能反过来给本仓库的算子换独立符号 —— 这也正是上游一直在用 `_vllm` 后缀的原因。

### 判定（30 秒）

1. 报错里出现 `in op store` 或 `op_info_parser ... 'NoneType' object is not subscriptable` → 就是这一类；
2. 确认对面那份内置算子确实存在：

```bash
find /usr/local/Ascend/cann-9.2.0/opp -maxdepth 10 -iname '*<算子名>*' 2>/dev/null | head
```

3. 顺带确认构建用的名字：

```bash
grep -n "op <算子名>" /home/s00988495/AFD/logs/afd_build_all.log | tail -3
# 期望：op <算子名>_vllm: dir=... cmake=yes op_host_cmake=yes
# 若还是旧名，说明改名那一步没生效
```

### 修复

脚本已经自动处理，**不需要手工改源码**：

| 算子 | 改名后 | 依据 |
|---|---|---|
| `kda_gate_cumsum` | `kda_gate_cumsum_vllm` | 上游 #17998（cherry-pick） |
| `chunk_gated_delta_rule_fwd_h` | `chunk_gated_delta_rule_fwd_h_vllm` | 上游 #17997 的改名部分 |
| `causal_conv1d` | `causal_conv1d_vllm` | 上游 #17727 是删掉改走 fla_npu；本基线还在用，故只改名 |

对应脚本第 9b 节（KDA cherry-pick）和第 9c 节（另两个改名）。
三个都只改符号名，**不碰任何计算逻辑**。

### 又冒出第四个算子怎么办

第 9c 节是表驱动的，加一条即可：

```bash
rename_custom_op \
    "<csrc 下的相对目录，如 moe/xxx>" \
    "<旧小写名>" \
    "<旧CamelCase名>" \
    "<旧大写名，可为空>" \
    "<目录外需要整文件改名的文件>" \
    "<目录外只改算子引用的 python 文件>" \
    "<不能跟着改的同前缀符号>" \
    || exit 1
```

要点：

- 大写 include guard 也要改（`CHUNK_GATED_DELTA_RULE_FWD_H_XXX_H` → `..._VLLM_XXX_H`），漏了会留下不一致的头文件；
- 同前缀的其它符号必须放进保护名单，否则会被误改。踩过的两个例子：
  `chunk_gated_delta_rule_fwd_hupdate`（triton helper）、`causal_conv1d_v310` / `npu_causal_conv1d_custom`；
- python 侧用第 6 个参数（只改 `torch.ops._C_ascend.<算子>` 和 `"<算子>"`），
  因为同名的 triton 函数**不能**改；
- 别漏 `__has_include` / 相对 include 的引用（踩过：`csrc/attention/chunk_kda_fwd/op_kernel/chunk_kda_fwd_common.h`）；
- 改完脚本自己会校验：`csrc` 里旧名清零、python 侧旧引用清零、工作树干净，任一不过就回滚。

---

## 二、构建目录残留：改名/删算子之后的 "not any obj compile success"

### 症状

```
[ERROR] op <改名前的算子名>: not any obj compile success
FAILED: [code=1] CMakeFiles/ops_config_<soc> binary/<soc>/bin/binary_info_config.json ...
```

注意报错里往往是**改名前的旧名字**。

### 根因

`csrc/build_aclnn.sh` 里有一句注释写得很直白：

```
log "preserving csrc/build and cleaning output dirs"
rm -rf -- output build_out
```

它只清 `output` 和 `build_out`，**故意保留 `csrc/build`**。
算子改名之后，`csrc/build` 里还留着改名前的算子目录和目标文件；
配置生成去扫这些残留，发现那个旧算子一个目标文件都没有 → 失败。

判定要点：如果报错里的名字在源码树里**已经不存在**（脚本的校验关卡会强制这一点），
那这个名字只可能来自保留的构建目录。

### 修复

脚本已自动处理：**只要真的在重建 vllm-ascend，就先删掉 `csrc/build`**。
手动等价操作：

```bash
rm -rf /home/s00988495/AFD/vllm-ascend/csrc/build
bash /home/s00988495/shell-utils/afd_build_and_compile.sh
```

代价是算子全量重编（几十分钟）。HEAD 没变的重复执行走 skip 分支，不受影响。

---

## 三、已确认的事实（别再重复排查）

- **`$ASCEND_OPP_PATH/vendors/cust` 与本问题无关**：它里面只有 `op_impl/aicpu/hybm`，
  不含这些算子。撞名的来源是 `opp/built-in/.../ops_transformer/`。
- 容器里 `ASCEND_CUSTOM_OPP_PATH` 是 unset；运行时由
  `vllm_ascend/utils.py` 的 `bootstrap_custom_op_env()` 把仓库内
  `_cann_ops_custom/vendors/...` prepend 进去。
- 日志是**追加**的，`grep -c` 得到的是历史累计值。判断"这一轮有没有新增"要么看行号，
  要么先定位本轮起点：

  ```bash
  S=$(grep -n "\[pr\] vLLM-Ascend PR" /home/s00988495/AFD/logs/afd_build_all.log | tail -1 | cut -d: -f1)
  tail -n +$S /home/s00988495/AFD/logs/afd_build_all.log | grep -n "FAILED:" | tail -5
  ```

- `ninja: build stopped: subcommand failed.` 只是汇总行，**真正的报错在它上面**，
  而且并行构建里可能离得很远。定位方式：

  ```bash
  n=$(grep -n "FAILED:" "$LOG" | tail -1 | cut -d: -f1); sed -n "$((n-3)),$((n+50))p" "$LOG"
  ```

- 日志里的 `[100%]` 是**某个子构建**的进度，不代表整体构建完成。

---

## 四、相关上游 PR 索引

| PR | 内容 | 状态 |
|---|---|---|
| #17998 | `kda_gate_cumsum` → `_vllm` | 已合（脚本 cherry-pick） |
| #17997 | `chunk_gated_delta_rule_fwd_h` → `_vllm` | 已合（脚本只取改名部分） |
| #17727 | 删掉 `causal_conv1d` / GDN state ops，改走 fla_npu | 已合（本基线仍在用，故改名而非删除） |
| #18002 | 同一算子的后续"restore + 唯一符号" | open |
| #18011 | `chunk_kda_fwd` → `chunk_kda_fwd_ascendc` | open |
| #17629 | 移除 deprecated 的 GDN 与 causal_conv1d 自定义算子 | open |

---

## 五、还没验证的部分

截至 2026-10-16，本容器上 vllm-ascend 的构建**最远只走到 OPP 配置生成这一带**，
下面这些环节一次都没成功跑过，遇到新报错不要假定它们是好的：

- OPP 打包与安装（`build.sh finished` / `installer finished`）
- `vllm_ascend_C` torch binding 编译
- afd-plugin 构建与 AFD 自定义算子
- 最终验证（import / AFD ops / a2e、e2a 产物）

另外 `causal_conv1d` 的改名是本地适配（上游是删除），
ACLNN 符号随算子类型自动生成这一点是从"仓库里没有手写的 `aclnnCausalConv1d` 声明"
推断出来的，**没有在真机上单独验证过**。如果这里出问题，报错会出现在
`EXEC_NPU_CMD(aclnnCausalConv1dVllm, ...)` 的编译或链接阶段。
