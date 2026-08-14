/*
 * X11/extensions/XTest.h — server-mode stub for the Monolith TinyX build.
 *
 * tinyx's mi/miinitext.c does `#define _XTEST_SERVER_` then
 * `#include <X11/extensions/XTest.h>`, but it uses NO symbol from the header:
 * XTestExtensionInit() and noTestExtensions are declared locally in that file.
 * The real libXtst XTest.h unconditionally pulls <X11/extensions/XInput.h>,
 * which drags the out-of-spec libXi/libXtst CLIENT libraries into the minimal
 * SERVER build. So, under the server guard, this header is intentionally empty;
 * outside it (client mode, which tinyx never uses) it defers to xtestconst.h.
 * See the ebuild's src_prepare for why this is vendored rather than depended.
 */
#ifndef _XTEST_H_
#define _XTEST_H_

#ifndef _XTEST_SERVER_
#include <X11/extensions/xtestconst.h>
#endif /* _XTEST_SERVER_ */

#endif /* _XTEST_H_ */
