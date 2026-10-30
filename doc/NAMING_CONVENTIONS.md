# Naming Conventions

This document defines naming conventions for COODA's RTL, simulation code,
scripts, and project documentation. Use these rules for new names. Existing
names may differ; do not rename a public interface, board pin, vendor primitive,
or file-format field unless all dependent code and constraints are updated.

## General rules

- Use descriptive names that communicate a signal's purpose, unit, polarity,
  or clock domain where relevant.
- Use `snake_case` for ordinary identifiers. Use `UPPER_SNAKE_CASE` for
  parameters, local parameters, constants, preprocessor macros, and fixed
  protocol values.
- Prefer complete words when practical. Keep common hardware terms such as
  `clk`, `rst`, `addr`, `data`, `req`, `rsp`, `cfg`, `min`, and `max`
  consistent throughout a module and its interface.
- Avoid positional, vague, or redundant names such as `sig1`, `temp`, `foo`,
  or `data_data`. Use an index only when the index is meaningful, such as a
  fixed bus client number.
- Use a suffix to express a role only when it has a clear and consistent
  meaning. Do not overload the same suffix with unrelated meanings.
- Names are case-sensitive. Do not rely on capitalization alone to distinguish
  related signals.

## Files and hierarchy

- Name SystemVerilog source files after their primary module or package, in
  lowercase `snake_case`, with the `.sv` extension: `cpu_core.sv`,
  `soc_pkg.sv`.
- Keep the primary module or package name identical to its source basename.
- Use lowercase `snake_case` for directories, testbench files, and scripts.
- Name instances with the `u_` prefix followed by the instantiated block's
  role or module: `u_cpu`, `u_memory_arbiter`.
- Name generate blocks with `gen_` followed by the generated function:
  `gen_ddr3`, `gen_no_sd`.
- Give generate block names distinct, meaningful names; avoid anonymous
  generate scopes when the scope is referenced hierarchically.

## Modules, packages, interfaces, and types

- Name modules, packages, interfaces, and program blocks in lowercase
  `snake_case`: `fpga_top`, `memory_sd`, `arch_pkg`.
- Use descriptive type names with a suffix:
  - `_t` for scalar, packed-vector, or alias types, such as `word_t`.
  - `_s` for packed structures, such as `bus_req_s`.
  - `_e` for enumerations, such as `bus_op_e` or `cpu_state_e`.
- Name a type for the concept it represents, not the module where it happens
  to be declared.
- Give each FSM a specific enum type (`sd_controller_state_e`, for example)
  rather than a generic `state_e` when the type is visible outside its local
  scope.
- Use `typedef enum logic [...]` with explicit encodings when encodings are
  part of an interface or implementation requirement.
- Use `typedef struct packed` for packed records. Name fields using the same
  field rules as signals and preserve a consistent field order across related
  request/response structures.

## Ports and signals

- Name ports and internal signals in lowercase `snake_case`.
- Name ports for their semantic role, not their direction. Do not add
  `in_`/`out_` prefixes: use `bus_req` and `bus_rsp`, not `in_bus_req` and
  `out_bus_rsp`.
- Use the same name for a signal across module boundaries when it represents
  the same interface concept. Use explicit mapping only when the parent has a
  distinct local meaning.
- Prefer paired request/response names such as `bus_req` / `bus_rsp` and
  `instr_req` / `instr_rsp`.
- Use plural or indexed names only for collections. When a fixed index
  identifies a protocol slot, retain it consistently (`req0` / `rsp0`).
  Prefer role-based names (`instr_req`, `data_req`) when the roles are known
  and the interface is not intentionally generic.
- Use suffixes consistently:
  - `_valid`, `_ready`, `_done`, `_busy`, `_enable` for handshake/status
    signals.
  - `_error` for an error indicator and `_err_code` for its code. Use `err`
    only in established protocol field names or when matching a vendor
    interface.
  - `_addr`, `_data`, `_count`, `_index`, and `_size` for values of those
    roles. Add a unit where it is not obvious, such as `_bytes` or `_cycles`.
- For active-low signals, use a `_n` suffix consistently for project-defined
  names: `reset_n`, `chip_select_n`. Keep board pin names and vendor-mandated
  names unchanged when constraints or IP require exact spelling.
- Include units in names for non-obvious physical or timing quantities:
  `timeout_cycles`, `delay_us`, `frequency_hz`. Do not encode units in
  unrelated names.
- Use descriptive clock names. Use `clk` for a module's primary clock when
  only one clock is present. For multiple domains, identify the domain
  consistently (`clk_sys`, `clk_ddr`, `clk_spi`); use the same domain suffix
  on its reset and synchronizer signals.
- Use `rst` for a synchronous or module-local reset where its behavior is
  clear. Distinguish asynchronous and active-low resets explicitly when
  needed (`rst_async`, `rst_n`). Document reset polarity and synchronization
  at the interface.
- For vectors, use a meaningful base name and declare width in the type,
  rather than encoding width in the identifier. Use `_lo` / `_hi` only when
  the split is meaningful and unambiguous.

## Sequential and combinational signals

- Use `_q` for a registered/current value and `_d` for its combinational
  next-state value. Keep the base name unchanged between the pair:
  `state_q` / `state_d`, `count_q` / `count_d`.
- Apply `_q` / `_d` consistently to FSM state and data-path registers when
  both registered and next-state forms exist.
- Do not add `_q` to purely combinational outputs or inputs.
- Name combinational intermediates by function (`grant_next`, `aligned`,
  `access`) rather than arbitrary temporary labels.
- Name flags as the condition or property they represent:
  `strobe_ok`, `cal_timeout`, `payload_valid`.
- In a clock-domain crossing, include the source/destination domain or
  synchronizer stage in internal names where it helps distinguish ownership,
  such as `req_toggle_sys`, `req_toggle_ddr_sync1`.

## FSMs and enum literals

- Name state variables `state_q` / `state_d`; if an FSM is not split into
  current and next values, use `state_q` for the registered state.
- Prefix enum literals with a short, consistent FSM-specific prefix and use
  `UpperCamelCase`, for example `SdIdle`, `SdReadBlock`,
  `DdrIdle`, `DdrRefresh`. Do not mix `StIdle`, `ST_IDLE`, and `IDLE` styles
  within project-defined FSMs.
- Use state names that describe actions or conditions, such as `WaitReady`,
  `ReadHeader`, or `ReportError`; keep names concise and unique within the
  enum.
- Keep enum literal names distinct from signal names, type names, and
  constants. Do not use the same generic state prefix for unrelated FSMs when
  names can be visible in a shared scope.
- For non-FSM enums, use a concept-specific `UpperCamelCase` prefix as in
  `BusRead`, `BusWrite`, or `OpAdd`.

## Parameters, constants, and macros

- Use `UPPER_SNAKE_CASE` for parameters, local parameters, package constants,
  and macros: `DDR3_BASE`, `MAX_BLOCKS`, `WORD_WIDTH`.
- Declare parameter and constant types explicitly whenever the toolchain
  supports it. Keep untyped parameters only where a documented tool
  limitation requires them.
- Name widths with `_WIDTH`, counts with `_COUNT`, byte capacities with
  `_BYTES`, and clock-cycle quantities with `_CYCLES`. Use `_W` only for
  short-lived, local width names when the meaning remains obvious.
- Include a unit or scope in ambiguous limits, for example
  `TOKEN_TIMEOUT_CYCLES` rather than `TOKEN_MAX`.
- Name feature switches as `<FEATURE>_ENABLE` or `<FEATURE>_EN`; choose one
  project-wide form and use it consistently. Prefer `_ENABLE`.
- Prefix macros with the subsystem or project when there is a risk of
  collision. Use include guards derived from the filename and ending in
  `_SV`, such as `SOC_PKG_SV`.
- Do not use macros for ordinary constants or expressions that can be
  represented by typed parameters, local parameters, or functions.

## Functions, tasks, assertions, and helpers

- Name functions and tasks in lowercase `snake_case`, beginning with an
  action or describing the result: `bus_is_aligned`, `make_flags`.
- Use descriptive argument names and types. Keep function argument names
  consistent with equivalent module ports and structure fields.
- Name assertion properties after the rule being checked, for example
  `request_stable_until_ready`.
- Name helper variables according to what they represent; avoid single-letter
  names except for conventional loop indices with very small scope.

## Bus and protocol naming

- Use `req` / `rsp` for request/response interfaces and `cmd` / `cmd_rsp`
  for command interfaces. Do not mix `ack`, `done`, and `ready` for the same
  handshake event; select the protocol's defined term and use it consistently.
- Use `addr`, `wdata`, `rdata`, `wstrb`, `op`, `valid`, `ready`, and `error`
  consistently in project-defined bus structures.
- Use `*_wr` and `*_rd` only for boolean read/write controls. Use `write` and
  `read` in longer descriptive identifiers where abbreviations would reduce
  clarity.
- Keep names and polarity faithful to the protocol. For example, `cs_n`
  communicates an active-low chip select; do not rename a protocol field in
  a way that obscures its active level.
- Preserve external protocol, board, and vendor pin spellings exactly where
  they are fixed by constraints, IP, generated code, or third-party models.
  Use the project convention for internal aliases around those interfaces.

## Testbench and simulation names

- Suffix testbench module and source names with `_tb`:
  `sd_loader_tb.sv`, `sd_loader_tb`.
- Name behavioral models after the modeled component with a `_model` suffix:
  `sd_model`.
- Prefix testbench-only controls and observations clearly, such as `fault_`,
  `expected_`, or `observed_`: `fault_no_token`, `expected_data`.
- Use `test_` or a descriptive action phrase for test tasks and checks.
- Name clocks, reset, and DUT-facing signals consistently with the RTL
  interface. Do not introduce a second spelling for the same signal in the
  testbench.
- Keep fault-injection names explicit about the injected condition and avoid
  names that imply a failure is active when it is only a configurable option.

## Python and project support files

- Use lowercase `snake_case` for Python modules, functions, variables, and
  filenames.
- Use `UPPER_SNAKE_CASE` for Python module-level constants.
- Use `CapWords` for Python classes and exception types.
- Use names that match the data format and units in scripts; keep CLI option
  names stable and descriptive.
- Use lowercase descriptive names for documentation files. Keep acronyms
  uppercase when they are established names, such as `README.md`.

## Examples

```systemverilog
module sd_loader #(
    parameter int MAX_BLOCKS = 65536
) (
    input  logic             clk_sys,
    input  logic             rst_sys,
    output logic             block_req,
    output logic [31:0]      block_addr,
    input  logic             block_done,
    output logic             load_error,
    output logic [3:0]       load_err_code
);
    typedef enum logic [2:0] {
        LoaderWait,
        LoaderReadHeader,
        LoaderWritePayload,
        LoaderDone,
        LoaderError
    } loader_state_e;

    loader_state_e state_q, state_d;
    logic [31:0] block_count_q, block_count_d;
    logic request_valid;
endmodule
```

In this example, the port names describe the interface, the state enum names
identify their FSM, `_q` / `_d` distinguish sequential and next-state values,
and the parameter uses uppercase `snake_case`.
