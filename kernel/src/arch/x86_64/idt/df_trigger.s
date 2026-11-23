/* Standalone assembly trigger for isolated Double Fault (#DF -> IST1) verification.
 * Linked exclusively into the isolated DF-test kernel executable, never production builds.
 */
.intel_syntax noprefix
.text
.global x86_64_trigger_df_unmapped_stack
.type x86_64_trigger_df_unmapped_stack, @function
x86_64_trigger_df_unmapped_stack:
    mov rsp, rdi
    push 0
.global x86_64_trigger_df_ud2_sentinel
x86_64_trigger_df_ud2_sentinel:
    ud2
