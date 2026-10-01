#include "values.h"
JSValue publr_js_undefined(void) { return JS_UNDEFINED; }
JSValue publr_js_null(void) { return JS_NULL; }
JSValue publr_js_number(JSContext *ctx, double value) { return JS_NewFloat64(ctx, value); }
JSValue publr_js_boolean(JSContext *ctx, int value) { return JS_NewBool(ctx, value); }
JSModuleDef *publr_js_module(JSValue value) { return JS_VALUE_GET_TAG(value) == JS_TAG_MODULE ? JS_VALUE_GET_PTR(value) : NULL; }
JSValue publr_js_exception(void) { return JS_EXCEPTION; }
