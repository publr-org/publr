#include "quickjs.h"
JSValue publr_js_undefined(void);
JSValue publr_js_null(void);
JSValue publr_js_number(JSContext *, double);
JSValue publr_js_boolean(JSContext *, int);
JSModuleDef *publr_js_module(JSValue);
JSValue publr_js_exception(void);
