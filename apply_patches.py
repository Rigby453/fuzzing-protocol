import sys, os

N2N = os.path.expanduser("~/Desktop/n2n")

# ─────────────────────────────────────────────
# Утилита: заменить первое вхождение anchor → anchor + insertion
# ─────────────────────────────────────────────
def insert_after(path, anchor, insertion, tag=""):
    with open(path) as f:
        content = f.read()
    if insertion.strip() in content:
        print(f"  [SKIP] {tag} уже применён в {path}")
        return True
    if anchor not in content:
        print(f"  [FAIL] anchor не найден в {path}:\n    {repr(anchor[:80])}")
        return False
    content = content.replace(anchor, anchor + insertion, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"  [OK]   {tag} → {path}")
    return True

def insert_before(path, anchor, insertion, tag=""):
    with open(path) as f:
        content = f.read()
    if insertion.strip() in content:
        print(f"  [SKIP] {tag} уже применён в {path}")
        return True
    if anchor not in content:
        print(f"  [FAIL] anchor не найден в {path}:\n    {repr(anchor[:80])}")
        return False
    content = content.replace(anchor, insertion + anchor, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"  [OK]   {tag} → {path}")
    return True

ok = True

# ═══════════════════════════════════════════════
# ПАТЧ 1 — determinism.patch
# ═══════════════════════════════════════════════
print("\n── PATCH 1: determinism ──")

# 1a. gettimeofday stub в начало supernode.c (перед #include "n2n.h")
ok &= insert_before(
    f"{N2N}/src/supernode.c",
    '#include "n2n.h"',
    '''#ifdef AFL_FUZZING
/* Deterministic timestamp for AFL: always return the same value */
#include <sys/time.h>
static int gettimeofday_orig(struct timeval *tv, struct timezone *tz) {
    if (tv) { tv->tv_sec = 1700000000; tv->tv_usec = 0; }
    return 0;
}
#define gettimeofday(tv, tz) gettimeofday_orig(tv, tz)
#endif

''',
    "gettimeofday stub"
)

# 1b. PRNG seed в main() после объявления переменных
# ищем "int rc;" — оно есть в main() supernode.c
ok &= insert_after(
    f"{N2N}/src/supernode.c",
    '    int rc;\n',
    '''
#ifdef AFL_FUZZING
    /* Fix PRNG seed for deterministic fuzzing */
    srand(0x41464c4e);   /* "AFLN" */
    srandom(0x41464c4e);
#endif
''',
    "PRNG seed"
)

# 1c. n2n_rand() stub в sn_utils.c после #include "n2n_wire.h"
ok &= insert_after(
    f"{N2N}/src/sn_utils.c",
    '#include "n2n_wire.h"',
    '''

#ifdef AFL_FUZZING
/*
 * Disable random community challenge generation — use a fixed value.
 * Without this, every REGISTER_SUPER response differs, making AFL think
 * each execution is a new path.
 */
static uint32_t afl_fixed_challenge = 0xDEADBEEF;
#define n2n_rand() (afl_fixed_challenge)
#endif
''',
    "n2n_rand stub"
)

# ═══════════════════════════════════════════════
# ПАТЧ 2 — sigterm_handler.patch
# ═══════════════════════════════════════════════
print("\n── PATCH 2: sigterm_handler ──")

# 2a. #include <signal.h> + handler после #include "sn_utils.h"
ok &= insert_after(
    f"{N2N}/src/supernode.c",
    '#include "sn_utils.h"',
    '''
#include <signal.h>

#ifdef AFL_FUZZING
static n2n_sn_t *g_sss_ptr = NULL;

static void afl_sigterm_handler(int sig) {
    (void)sig;
    if (g_sss_ptr) {
        /* Close all sockets to release ports immediately */
        if (g_sss_ptr->sock >= 0) {
            shutdown(g_sss_ptr->sock, SHUT_RDWR);
            close(g_sss_ptr->sock);
            g_sss_ptr->sock = -1;
        }
        if (g_sss_ptr->mgmt_sock >= 0) {
            close(g_sss_ptr->mgmt_sock);
            g_sss_ptr->mgmt_sock = -1;
        }
    }
#ifdef __GNUC__
    /* Flush gcov data before exit so coverage is recorded */
    extern void __gcov_flush(void);
    __gcov_flush();
#endif
    _exit(0);   /* _exit: skip atexit handlers, release fd fast */
}
#endif /* AFL_FUZZING */
''',
    "SIGTERM handler"
)

# 2b. регистрация сигналов в main() после PRNG seed блока
ok &= insert_after(
    f"{N2N}/src/supernode.c",
    '    srandom(0x41464c4e);\n#endif\n',
    '''
#ifdef AFL_FUZZING
    g_sss_ptr = &sss;
    signal(SIGTERM, afl_sigterm_handler);
    signal(SIGINT,  afl_sigterm_handler);
#endif
''',
    "signal registration"
)

# ═══════════════════════════════════════════════
# ПАТЧ 3 — gcov.patch (CMakeLists.txt)
# ═══════════════════════════════════════════════
print("\n── PATCH 3: gcov / CMakeLists.txt ──")

ok &= insert_after(
    f"{N2N}/CMakeLists.txt",
    'project(n2n C)',
    '''

# -------------------------------------------------------
# Coverage build option (used for LCOV reports)
# Usage: cmake -DFUZZING_COVERAGE=ON ...
# -------------------------------------------------------
option(FUZZING_COVERAGE "Enable gcov coverage instrumentation" OFF)
if(FUZZING_COVERAGE)
    message(STATUS "Coverage build enabled")
    add_compile_options(-O0 -g --coverage -fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
    add_compile_definitions(AFL_FUZZING)
endif()

option(AFL_FUZZING_BUILD "Enable AFL determinism patches" OFF)
if(AFL_FUZZING_BUILD)
    add_compile_definitions(AFL_FUZZING)
endif()
''',
    "cmake coverage options"
)

# ═══════════════════════════════════════════════
print("\n" + ("═"*40))
print("Результат:", "ВСЕ ПАТЧИ ПРИМЕНЕНЫ ✓" if ok else "ЕСТЬ ОШИБКИ — см. выше ✗")
print("═"*40)
