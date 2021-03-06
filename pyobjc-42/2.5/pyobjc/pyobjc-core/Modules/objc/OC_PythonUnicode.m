#include "pyobjc.h"
#import "OC_PythonUnicode.h"

@implementation OC_PythonUnicode 

+ newWithPythonObject:(PyObject*)v;
{
	OC_PythonUnicode* res;

	res = [[OC_PythonUnicode alloc] initWithPythonObject:v];
	[res autorelease];
	return res;
}

- initWithPythonObject:(PyObject*)v;
{
	Py_INCREF(v);
	Py_XDECREF(value);
	value = v;
	return self;
}


-(PyObject*)__pyobjc_PythonObject__
{
	Py_INCREF(value);
	return value;
}

-(PyObject*)__pyobjc_PythonTransient__:(int*)cookie
{
	*cookie = 0;
	Py_INCREF(value);
	return value;
}



-(void)release
{
	/* There is small race condition when an object is almost deallocated
	 * in one thread and fetched from the registration mapping in another
	 * thread. If we don't get the GIL this object might get a -dealloc
	 * message just as the other thread is fetching us from the mapping.
	 * That's why we need to grab the GIL here (getting it in dealloc is
	 * too late, we'd already be dead).
	 */
	/* FIXME: it should be possible to grab the lock only when really
	 * needed, but the test below isn't good enough. Be heavy handed to
	 * make sure we're right, rather than crashing sometimes anyway.
	 */
	/* FIXME2: in rare occasions we're trying to acquire the GIL during 
	 * shutdown and if we're very unlucky this can happen after the 
	 * GILState machinery has shut down...
	 */
#if 0
	if ([self retainCount] == 1) {
#endif
		PyObjC_BEGIN_WITH_GIL
			[super release];
		PyObjC_END_WITH_GIL
#if 0
	} else {
		[super release];
	}
#endif
}

-(void)dealloc
{
	PyObjC_BEGIN_WITH_GIL
		PyObjC_UnregisterObjCProxy(value, self);
#ifndef PyObjC_UNICODE_FAST_PATH
		[realObject release];
#endif /* !PyObjC_UNICODE_FAST_PATH */
		Py_XDECREF(value);
	PyObjC_END_WITH_GIL

	[super dealloc];
}

#ifdef PyObjC_UNICODE_FAST_PATH

-(NSUInteger)length
{
	return (NSUInteger)PyUnicode_GET_SIZE(value);
}

-(unichar)characterAtIndex:(NSUInteger)anIndex
{
	if (anIndex > PY_SSIZE_T_MAX) {
		[NSException raise:@"NSRangeException" format:@"Range or index out of bounds"];
	}
	if (anIndex >= (NSUInteger)PyUnicode_GET_SIZE(value)) {
		[NSException raise:@"NSRangeException" format:@"Range or index out of bounds"];
	}
	return PyUnicode_AS_UNICODE(value)[anIndex];
}

-(void)getCharacters:(unichar *)buffer range:(NSRange)aRange
{
	if (aRange.location + aRange.length > (NSUInteger)PyUnicode_GET_SIZE(value)) {
		[NSException raise:@"NSRangeException" format:@"Range or index out of bounds"];
	}
	memcpy(buffer, 
	       PyUnicode_AS_UNICODE(value) + aRange.location, 
	       sizeof(unichar) * aRange.length);
}

#else /* !PyObjC_UNICODE_FAST_PATH */

-(id)__realObject__
{
	if (!realObject) {
		PyObjC_BEGIN_WITH_GIL
			PyObject* utf8 = PyUnicode_AsUTF8String(value);
			if (!utf8) {
				NSLog(@"failed to encode unicode string to UTF8");
				PyErr_Clear();
			} else {
				realObject = [[NSString alloc]
					initWithBytes:PyString_AS_STRING(utf8)
					       length:(NSUInteger)PyString_GET_SIZE(value)
					     encoding:NSUTF8StringEncoding];
				Py_DECREF(utf8);
			}
		PyObjC_END_WITH_GIL
	}
	return realObject;
}
	
-(NSUInteger)length
{
	return [((NSString *)[self __realObject__]) length];
}

-(unichar)characterAtIndex:(NSUInteger)anIndex
{
	return [((NSString *)[self __realObject__]) characterAtIndex:anIndex];
}

-(void)getCharacters:(unichar *)buffer range:(NSRange)aRange
{
	[((NSString *)[self __realObject__]) getCharacters:buffer range:aRange];
}


#endif /* PyObjC_UNICODE_FAST_PATH */

/*
 * NSCoding support 
 *
 * We need explicit NSCoding support to get full fidelity, otherwise we'll
 * get archived as generic NSStrings.
 */
- (id)initWithCharactersNoCopy:(unichar *)characters 
			length:(NSUInteger)length 
		  freeWhenDone:(BOOL)flag
{
#ifndef PyObjC_UNICODE_FAST_PATH
# error "Wide UNICODE builds are not supported at the moment"
#endif
	PyObjC_BEGIN_WITH_GIL
		value = PyUnicode_FromUnicode((Py_UNICODE*)characters, length);
		if (value == NULL) {
			PyObjC_GIL_FORWARD_EXC();
		}

	PyObjC_END_WITH_GIL;
	if (flag) {
		free(characters);
	}
	return self;
}


/* 
 * Helper method for initWithCoder, needed to deal with
 * recursive objects (e.g. o.value = o)
 */
-(void)pyobjcSetValue:(NSObject*)other
{
	PyObject* v = PyObjC_IdToPython(other);
	Py_XDECREF(value);
	value = v;
}

- initWithCoder:(NSCoder*)coder
{
	int ver;
	if ([coder allowsKeyedCoding]) {
		ver = [coder decodeInt32ForKey:@"pytype"];
	} else {
		[coder decodeValueOfObjCType:@encode(int) at:&ver];
	}
	if (ver == 1) {
		self = [super initWithCoder:coder];
		return self;
	} else if (ver == 2) {

		if (PyObjC_Decoder != NULL) {
			PyObjC_BEGIN_WITH_GIL
				PyObject* cdr = PyObjC_IdToPython(coder);
				if (cdr == NULL) {
					PyObjC_GIL_FORWARD_EXC();
				}

				PyObject* setValue;
				PyObject* selfAsPython = PyObjCObject_New(self, 0, YES);
				setValue = PyObject_GetAttrString(selfAsPython, "pyobjcSetValue_");

				PyObject* v = PyObject_CallFunction(PyObjC_Decoder, "OO", cdr, setValue);
				Py_DECREF(cdr);
				Py_DECREF(setValue);
				Py_DECREF(selfAsPython);

				if (v == NULL) {
					PyObjC_GIL_FORWARD_EXC();
				}

				Py_XDECREF(value);
				value = v;

				NSObject* proxy = PyObjC_FindObjCProxy(value);
				if (proxy == NULL) {
					PyObjC_RegisterObjCProxy(value, self);
				} else {
					[self release];
					[proxy retain];
					self = (OC_PythonUnicode*)proxy;
				}


			PyObjC_END_WITH_GIL

			return self;

		} else {
			[NSException raise:NSInvalidArgumentException
					format:@"decoding Python objects is not supported"];
			return nil;

		}
	} else {
		[NSException raise:NSInvalidArgumentException
			format:@"encoding Python objects is not supported"];
		return nil;
	}
}

-(void)encodeWithCoder:(NSCoder*)coder
{
	if (PyUnicode_CheckExact(value)) {
		if ([coder allowsKeyedCoding]) {
			[coder encodeInt32:1 forKey:@"pytype"];
		} else {
			int v = 1;
			[coder encodeValueOfObjCType:@encode(int) at:&v];
		}
		[super encodeWithCoder:coder];
	} else {
		if ([coder allowsKeyedCoding]) {
			[coder encodeInt32:2 forKey:@"pytype"];
		} else {
			int v = 2;
			[coder encodeValueOfObjCType:@encode(int) at:&v];
		}

		PyObjC_encodeWithCoder(value, coder);
	}
}

#if 1


-(NSObject*)replacementObjectForArchiver:(NSArchiver*)archiver 
{
	(void)(archiver);
	return self;
}

-(NSObject*)replacementObjectForKeyedArchiver:(NSKeyedArchiver*)archiver
{
	(void)(archiver);
	return self;
}

-(NSObject*)replacementObjectForCoder:(NSCoder*)archiver
{
	(void)(archiver);
	return self;
}

-(NSObject*)replacementObjectForPortCoder:(NSPortCoder*)archiver
{
	(void)(archiver);
	return self;
}

-(Class)classForArchiver
{
	return [OC_PythonUnicode class];
}

-(Class)classForKeyedArchiver
{
	return [OC_PythonUnicode class];
}

-(Class)classForCoder
{
	return [OC_PythonUnicode class];
}

-(Class)classForPortCoder
{
	return [OC_PythonUnicode class];
}

/* Ensure that we can be unarchived as a generic string by pure ObjC
 * code.
 */
+classFallbacksForKeyedArchiver
{
	return [NSArray arrayWithObject:@"NSString"];
}

#endif

@end /* implementation OC_PythonUnicode */
