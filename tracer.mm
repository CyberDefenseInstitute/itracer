
#include <substrate.h>

#include <pthread.h>
#include <unistd.h>

#include <stdlib.h>
#include <stdio.h>
#include <dlfcn.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdarg.h>

#include <string>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <vector>

using namespace std;

extern "C" {
#define FUNC(symbol, prototype) void *old_##symbol; extern void *replaced_##symbol();
#include "objc_funcs.h"
#undef FUNC
}

//------------------------------------------------------------------------------
// チューニング部分 =>
//------------------------------------------------------------------------------

#define	LOG_THREADING		1

// 開発中のデバッグメッセージ
//#define	DBGMSG( flg, fmt, ... )	flg ? dbgmsg( fmt "\n", ##__VA_ARGS__ ), 1: 0
#define	DBGMSG( flg, ... )	

// 引数無しのメソッドのトレース情報を出力するか否か
#define	TRACE_NO_ARG_METHOD	0

static pthread_mutex_t DbgLock = PTHREAD_MUTEX_INITIALIZER;

static void dbgmsg(const char *fmt, ...) {
	va_list arg;
    va_start(arg, fmt);
	
    pthread_mutex_lock( &DbgLock );
    {
		FILE *f = fopen("/tmp/itracer.dbg", "a");
		vfprintf(f, fmt, arg);
		fclose(f);
	}
	pthread_mutex_unlock( &DbgLock );
	
	va_end(arg);
}

/**
 * トレース除外判定
 * 
 * @param	className		レシーバクラス名
 * @param	selectorName	レシーバセレクタ名
 *
 * @return	true:除外
 */
static bool isIgnoreRequest( const char *className, const char *selectorName ) {

#define	IS_MATCH( a, b )	( 0 == strcmp( a, b ) )
#define	STARTWITH( a, b )	( 0 == strncmp( a, b, sizeof( a ) - 1 ) )
#define	IGNORE_CLASS( ignoreClass )	if( IS_MATCH( #ignoreClass, className ) ){ return true; }
#define	IGNORE_CLASS_STARTWITH( ignoreClass )	if( STARTWITH( #ignoreClass, className ) ){ return true; }
#define	IGNORE_METHOD( ignoreMethod )	if( IS_MATCH( #ignoreMethod, selectorName ) ){ return true; }
#define	IGNORE_METHOD_STARTWITH( ignoreMethod )	if( STARTWITH( #ignoreMethod, selectorName ) ){ return true; }
#define	IGNORE_CLASS_METHOD( ignoreClass, ignoreMethod )	if( IS_MATCH( #ignoreClass, className ) && IS_MATCH( #ignoreMethod, selectorName ) ){ return true; }

	// c++ classがNSObjectを継承しているのか、ブロックしないと死ぬ。
	IGNORE_CLASS( NSObject );
	
	// 描画関係で、多いやつ。
	IGNORE_CLASS( CALayer );	
	IGNORE_CLASS( CALayerArray );
	IGNORE_CLASS( UIImage );
	IGNORE_CLASS( UIImageView );
	IGNORE_CLASS( UIImageTableArtwork );
	IGNORE_CLASS( UIWindowLayer );
	/*
	UIStatusBar
	UIStatusBarWindow
	UIStatusBarComposedData
	UIStatusBarCorners
	UIStatusBarBackgroundView
	UIStatusBarItem
	UIStatusBarLayoutManager
	UIStatusBarServiceItemView
	UIStatusBarDataNetworkItemView
	UIStatusBarForegroundView
	UIStatusBarBatteryPercentItemView
	*/
	IGNORE_CLASS_STARTWITH( UIStatusBar );
	
	// 役に立たない
	IGNORE_METHOD( class );
	IGNORE_METHOD( alloc );
	IGNORE_METHOD( release );
	IGNORE_METHOD( dealloc );
	IGNORE_METHOD( retain );
	IGNORE_METHOD( autorelease );
	IGNORE_METHOD( retainCount );
	IGNORE_METHOD( init );
	IGNORE_METHOD( lock );
	IGNORE_METHOD( unlock );
	IGNORE_METHOD( copy );
	IGNORE_METHOD( _dispose );
	IGNORE_METHOD( copyWithZone: );
	IGNORE_METHOD( objectAtIndex: );
	IGNORE_METHOD( characterAtIndex: );
	IGNORE_METHOD( countByEnumeratingWithState:objects:count: );

	// クラッシュしちゃうのでとりあえず除外
	IGNORE_CLASS_METHOD( WebDataSource, _initWithDocumentLoader: );
	IGNORE_CLASS_METHOD( LocalAreaRemoteAccessDeviceSearchManager, respondsToSelector: );
	
	return false;
}


//------------------------------------------------------------------------------
// チューニング部分 <=
//------------------------------------------------------------------------------


static void dump( unsigned char *p, size_t sz ){
	unsigned int i;
	for(i = 0; i< sz; i++){
		fprintf( stderr, "%02x ", p[i] );
	}
	fprintf( stderr, "\n" );
}

static void printStringObject( const char *printString, ostringstream &prmString ) {
	const char *str = "";
	if( printString ){
		str = printString;
	}
	prmString << "\"" <<  str << "\"";
}

/**
 * NSNumber型オブジェクトの解析
 * gdbで確認した結果、7-8バイト目のシグネチャで区別しているようだったのでそのように実装。
 * ちなみに5バイト目には領域のサイズが入っているようだった。
 * Int,Float : 1
 * Double : 2
 */
static void printNumberObject( ostringstream &prmString, id obj ) {
	unsigned *p = (unsigned *)obj;
	unsigned sig = p[1] & 0x0000FFFF;
	switch( sig ) {
	case 0x1683:	// Int
		prmString << ( signed )p[2];
		break;
	case 0x1685:	// Float
	{
		prmString << fixed << *( ( float * )( &p[2] ) );
		break;
	}
	case 0x1686:	// Double
		prmString << fixed << *( ( double * )( &p[2] ) );
		break;
	default:	// unknown
		prmString << (unsigned)p[2] << "_<type:" << sig << ">";
		break;
	}
}

/**
 * クラスオブジェクトの解析
 * gdbでデバッグしてオフセットを出してるので、iOSやフレームワークバージョンでずれる可能性あり。
 * メンテナンスが必要。
 * 
 * @param	obj			解析対象クラスオブジェクト
 * @param	prmString	パラメタ解析結果文字列
 */
static void printObject( id obj, ostringstream &prmString ) {

#pragma pack(1)
typedef struct{
	id	isa;
	id	unknown;
	unsigned char	sz;
	char	str[];
} CFStringStructure;

typedef struct {
	id	isa;
	char	rsv[4];
	short	str[];
} NSPathStore2Structure;
#pragma pack()

DBGMSG( 1, "/%x/", obj );


	if( nil == obj ){
		prmString << "nil";
		return;
	}
	if( ((unsigned)obj & 0x3) || ((unsigned)obj <= 0xf) ) {
		prmString << "badptr_object";
		return;
	}

	Class cls = object_getClass( obj );
	if( Nil == cls ) {
		prmString << "no-Class";
		return;
	}
	char *className = (char *)class_getName( cls );
	if( NULL == className ) {
		prmString << "no-ClassName";
		return;
	}

	if( class_isMetaClass( cls ) ) {
		prmString << "<" << className << " MetaClass>";
		return;
	}

DBGMSG( 1, "/%s/", className );

	prmString << "<" << className << ">";
	if( 0 == strcmp( "__NSCFConstantString", className ) ) {
		unsigned *p = (unsigned *)obj;
		printStringObject( ( char * )( p[2] ), prmString );
		return;
	}
	if( 0 == strcmp( "__NSCFString", className ) ) {
		CFStringStructure *cfstr = (CFStringStructure *)obj;
		printStringObject( cfstr->str, prmString );
		return;
	}
	if( 0 == strcmp( "NSPathStore2", className ) ) {
		NSPathStore2Structure *pathstr = ( NSPathStore2Structure * )obj;
		prmString << "\"";
		for( unsigned i = 0;  0 != pathstr->str[i]; i++ ){
			prmString << (char)pathstr->str[i];
		}
		prmString << "\"";
		return;
	}
	if( 0 == strcmp( "NSURL", className ) ) {
		unsigned *p = (unsigned *)obj;
		CFStringStructure *cfstr = (CFStringStructure *)p[4];
		printStringObject( cfstr->str, prmString );
		return;
	}
	if( 0 == strcmp( "__NSCFNumber", className ) ) {
		printNumberObject( prmString, obj );
		return;
	}
	if( 0 == strcmp( "__NSArrayI", className ) ) {
		unsigned *p = (unsigned *)obj;
		unsigned count = p[1];
		prmString << "[ ";
		for( unsigned i = 0; i < count; i++ ){
			printObject( (id)( p[ i + 2 ] ), prmString );
			prmString << " ";
		}
		prmString << "]";
		return;
	}
}

typedef struct {
	unsigned	argNum;
	unsigned	arg[2];
	va_list 	varg;
} ArgInfo;

/**
 * メソッドのパラメタ解析
 *
 * @param	method		メソッド情報
 * @param	r2			メソッドの第1引数
 * @param	r3			メソッドの第2引数
 * @param	__args		第3引数以降の可変長引数リスト
 * @param	prmString	パラメタ解析結果文字列
 * 
 * @see		https://developer.apple.com/library/ios/#documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
 */
static bool parseParam( Method method, const ArgInfo &argInfo, ostringstream &prmString ) {

	// 引数の数を取得
	unsigned prmCount = method_getNumberOfArguments( method );
	if( 2 >= prmCount ) {
		// 2以下だったら、引数なしと判定
		// 引数0でも以下の情報が固定で入ってくるため。
		// 1個目 : レシーバ
		// 2個目 : セレクタ
#if TRACE_NO_ARG_METHOD
		return true;
#else
		return false;
#endif
	}

	// メソッドの型情報文字列を取得
	char *prmExp = ( char * )method_getTypeEncoding( method );
	if( nil == prmExp ) {
#if TRACE_NO_ARG_METHOD
		return true;
#else
		return false;
#endif
	}
	size_t argTypeBufLen = strlen( prmExp );
	vector< char > argType( argTypeBufLen );

	// 引数のバイト数を取得
	method_getReturnType( method, &argType[0], argTypeBufLen );
	unsigned returnTypeLen = strlen( &argType[0] );
	unsigned argSize = atoi( &prmExp[ returnTypeLen ] );

	// 全ての引数を連続したアドレスで扱えたら以降の処理が楽なので、バッファ確保してコピー
	vector< unsigned > argBuf( 2/* r2, r3 */ + ( argSize / sizeof( unsigned ) ) + 1 );
	for( unsigned i = 0; i < argInfo.argNum; i++ ){
		argBuf[i] = argInfo.arg[i];
	}
	memcpy( &argBuf[ argInfo.argNum ], argInfo.varg, argSize );
	va_list args = &argBuf[0];	// 全ての引数が詰まった引数リスト完成

	unsigned parsedOffset = returnTypeLen;	// メソッドの型情報文字列をパースしたオフセット
	while( ':' != prmExp[ ++parsedOffset ] ); // セレクタまで進める
	while( isdigit( (int)prmExp[ ++parsedOffset ] ) );	// セレクタのサイズを捨てる。4固定っぽいけど。

DBGMSG( 1, "prmCount:%u prmExp:%s argSize:%u parsedOffset:%u#", prmCount, prmExp, argSize, parsedOffset );

	for( unsigned prmIndex = 2; prmIndex < prmCount; prmIndex++ ) {

		//prmString << ( ( 2 == prmIndex ) ? " " : ", " );
		prmString << std::endl << "\t";

		// 指定番目のパラメタ型情報を取得
		method_getArgumentType( method, prmIndex, &argType[0], argTypeBufLen );

		// オフセットを進める
		unsigned argTypeLen = strlen( &argType[0] );
		parsedOffset += argTypeLen;

		// 引数の[メソッドの型情報文字列]内のオフセットを取得
		unsigned prmOffset = atoi( &prmExp[ parsedOffset ] ) - 8/* オブジェクト、セレクタ分 */;
		while( isdigit( (int)prmExp[ ++parsedOffset ] ) );

DBGMSG( 1, "{%u:%s %u %u} ", prmIndex, &argType[0], prmOffset, parsedOffset );

		// 引数リストのアドレスを再設定。まだパースできないパラメタがあるので。
		args = &argBuf[ prmOffset / 4 ];

		bool isHit = true;
		unsigned	depth = 0;
		char *type = ( char * )&argType[0];
		do {

			if( depth ) {
				prmString << " ";
			}

DBGMSG( 1, "`%c`", *type );
			isHit = true;
			switch( *type ) {

			case '\0':
				break;

			case 'c':	// A char
			{
				signed char value( va_arg( args, int ) );
				prmString << "(char)" << (signed)value;
				if( isprint( value ) ) {
					prmString << "'" << value << "'";
				}
				break;
			}
			case 'i':	// An int
			{
				int value( va_arg( args, int ) );
				prmString << "(int)" << value;
				break;
			}
			case 's':	// A short
			{
				short value( va_arg( args, int ) );
				prmString << "(short)" << value;
				break;
			}
			case 'l':	// A long
			{
				long value( va_arg( args, long ) );
				prmString << "(long)" << value;
				break;
			}
			case 'q':	// A long long
			{
				long long value( va_arg( args, long long ) );
				prmString << "(longlong)" << value;
				break;
			}
			case 'C':	// An unsigned char
			{
				unsigned char value( va_arg( args, unsigned int ) );
				prmString << "(uchar)" << (unsigned)value;
				break;
			}
			case 'I':	// An unsigned int
			{
				unsigned int value( va_arg( args, unsigned int ) );
				prmString << "(uint)" << value;
				break;
			}
			case 'S':	// An unsigned short
			{
				unsigned short value( va_arg( args, unsigned int ) );
				prmString << "(ushort)" << value;
				break;
			}
			case 'L':	// An unsigned long
			{
				unsigned long value( va_arg( args, unsigned long ) );
				prmString << "(ulong)" << value;
				break;
			}
			case 'Q':	// A unsigned long long
			{
				unsigned long long value( va_arg( args, unsigned long long ) );
				prmString << "(ulonglong)" << value;
				break;
			}
			case 'f':	// A float
			{
				union {
					uint32_t i;
					float f;
				} value = { va_arg( args, uint32_t ) };
				prmString << "(float)" << value.f;
				break;
			}
			case 'd':	// A double
			{
				double value( va_arg( args, double ) );
				prmString << "(double)" << value;
				break;
			}
			case 'B':	// A C++ bool or a C99 _Bool
			{
				bool value( va_arg( args, int ) );
				prmString << "(bool)" << value;
				break;
			}

			case '#':	// A class object (Class)
			case '@':	// An object (whether statically typed or typed id)
			{
				id value( va_arg( args, id ) );
				printObject( value, prmString );
				break;
			}

			case ':':	// A method selector (SEL)
			{
				SEL value( va_arg( args, SEL ) );
				if( nil == value ){
					prmString << "@selector-nil";
				} else if( (unsigned)value & 0x3 ) {
					prmString << "@selector-bad_ptr";
				} else {
					prmString << "@selector(" << sel_getName( value ) << ")";
				}
				break;
			}

			case '*':	// A character string (char *)
			{
				const char *value( va_arg( args, const char *) );
				printStringObject( value, prmString );
				break;
			}

			case '^':	// A pointer to type
			{
				void *value( va_arg( args, void * ) );
				prmString << "(ptr)" << std::hex << std::showbase << value << std::dec;
				break;
			}

			case 'N':	// in out
			case 'n':	// in
			case 'O':	// by copy
			case 'o':	// out
			case 'R':	// byref
			case 'r':	// const
			case 'V':	// oneway
				// ignore them
				isHit = false;
				break;

			case '[':	// An array
				// not supported.
				prmString << "[array(not supported)]";
				break;
			case '{':	// A structure
			case '(':	// A union
				prmString << *type++ << " ";
				while( '=' != *type ) {
					prmString << *type;
					type++;
				}
				depth++;
				break;
			case ']':
			case '}':
			case ')':
				prmString << *type;
				depth--;
DBGMSG(1, " @depth %d ", depth);
				break;
			case 'b':	// A union
				break;	

			default:
				//prmString << "unknown_parameter_type<" << type << ">";
				break;
			}

			type++;
		} while( ( false == isHit ) || ( 0 < depth ) );
	}

	prmString << std::endl;
	return true;
}

static char LogFileName[256];
static pthread_mutex_t Lock = PTHREAD_MUTEX_INITIALIZER;

#if	LOG_THREADING

static pthread_t Thread;
static char LogBuf[20 * 1024 * 1024];
static unsigned LogIndex = 0;

static void logFlush() {
	FILE *f = fopen(LogFileName, "a");
	fwrite( LogBuf, LogIndex, 1, f ); 
	fclose(f);
	LogIndex = 0;
}

static void logThread() {
	
	unsigned sts = 0;
	do {
		sts = sleep( 1 );
		
		pthread_mutex_lock( &Lock );
		{
			if( LogIndex > 0 ) {
				logFlush();
			}
		}
		pthread_mutex_unlock( &Lock );		
	} while( 0 == sts );
}

#endif

/**
 * objective-cメッセージトレース
 *
 * @param	receiver	レシーバ（メッセージを受信するオブジェクト）
 * @param	cls			クラス情報
 * @param	op			メソッド名（セレクタ）
 * @param	r2			メソッドの第1引数
 * @param	r3			メソッドの第2引数
 * @param	arg			第3引数以降の可変長引数リスト
 */
static void msgTrace( id receiver, Class cls, SEL op, const ArgInfo &argInfo ) {

	if( nil == cls ) {
		cls = object_getClass( receiver );
	}
	if( (unsigned)cls & 0x3 ) {
		return;
	}

	// レシーバのクラス名、セレクタを取得	
	const char *className = object_getClassName( cls );
	if( ( nil == cls ) || ( (unsigned)cls & 0x3 ) ) {
		return;
	}
	if( ( nil == op ) || ( (unsigned)op & 0x3 ) ) {
		return;
	}
	const char *selectorName = sel_getName( op );
	if( ( NULL == selectorName ) || ( (unsigned)selectorName & 0x3 ) ) {
		return;
	}

#if 0	/* for debug */
	pthread_mutex_lock( &Lock );
	{
		if( ( LogIndex + strlen(className) + strlen(selectorName) + 5 ) > sizeof( LogBuf ) ) {
			logFlush();
		}
		LogIndex += sprintf( &LogBuf[ LogIndex ], "[%s %s]\n", className, selectorName );
	}		
	pthread_mutex_unlock( &Lock );
	return;
#endif
	
	// トレース除外チェック
	if( isIgnoreRequest( className, selectorName ) ) {
DBGMSG( 1, "    ---- %s %s\n", className, selectorName );
		return;
	}
DBGMSG( 1, "/%s %s/", className, selectorName );

	// インスタンスメソッド情報取得
	Method method = class_getInstanceMethod( cls, op );
	if( nil == method ) {
		// 失敗。クラスメソッド？
		method = class_getClassMethod( cls, op );
		if( nil == method ){
			// ダメでした・・・orz
			//fprintf( stderr, "*** %s %s nil method\n", className, selectorName );
			return;
		}
	}

	// メソッドのパラメタ解析
	bool isSuccess = true;
	ostringstream prmString;
	
	try {
		@try {
			isSuccess = parseParam( method, argInfo, prmString );
		} @catch( ... ) {
			prmString << "exception occur(oc)";
		}
	} catch( ... ){
		prmString << "exception occur(c++)";
	}
	
	if( isSuccess ){
		// トレース情報出力
		string logString = prmString.str();
		unsigned logLength = logString.size();
		
		pthread_mutex_lock( &Lock );
		{
#if LOG_THREADING
			if( ( LogIndex + logLength ) > sizeof( LogBuf ) ) {
				logFlush();
			}			
			LogIndex += sprintf( &LogBuf[ LogIndex ], "[%s %s]%s\n", className, selectorName, logString.c_str() );
#else
			FILE *f = fopen(LogFileName, "a");
			fprintf( f, "[%s %s]%s\n", className, selectorName, logString.c_str() );
			fclose(f);
#endif
		}		
		pthread_mutex_unlock( &Lock );
	}
}

/**
 * 可変長引数の開始アドレス計算。
 * hijack_arm.Sでスタック退避（stmdb	sp!, {r0-r12, lr}）を行っているため、
 * スタックポインタが移動している。
 * => 可変長引数の開始アドレスも同じだけずれているので、アドレスを修正する必要がある。
 *
 * @param	arg		修正前の可変長引数のアドレス
 */
static va_list adjustStdArgAddr( va_list arg ) {
	// レジスタ14個分
	return ( va_list )( ((unsigned)arg) + ( 14 * 4 ) );
}



/**
 * 普通のobjc_msgSend
 *
 * @param	receiver	レシーバ（メッセージを受信するオブジェクト）
 * @param	op			メソッド名（セレクタ）
 * @param	r2			メソッドの第1引数
 * @param	r3			メソッドの第2引数
 * @param	...			第3引数以降の可変長引数リスト
 * 
 * @note 本関数呼び出しの前に、hijack_arm.Sでスタック退避を行っているため、可変長引数の開始アドレスをadjustStdArgAddrで修正する必要がある
 */
extern "C"
void msg_debug_regular( id receiver, SEL op, unsigned r2, unsigned r3, ... ) {
	va_list arg;
	va_start( arg, r3 );
	ArgInfo argInfo = { 2, { r2, r3 }, adjustStdArgAddr( arg ) };
	msgTrace(receiver, nil, op, argInfo );
	va_end( arg );
}

/**
 * 構造体の戻り値を受け取るタイプ
 * 
 * @param	stretAddr	戻り値を受けるアドレス
 * @param	receiver	レシーバ（メッセージを受信するオブジェクト）
 * @param	op			メソッド名（セレクタ）
 * @param	r3			メソッドの第1引数
 * @param	...			第3引数以降の可変長引数リスト
 */
extern "C"
void msg_debug_stret( void *stretAddr, id receiver, SEL op, unsigned r3, ... ) {
	va_list arg;
	va_start( arg, r3 );
	ArgInfo argInfo = { 1, { r3, 0 }, adjustStdArgAddr( arg ) };
	msgTrace(receiver, nil, op, argInfo );
	va_end( arg );
}

/**
 * スーパークラスインスタンス構造体
 *
 * @note	まんま同じ構造体objc_superがあるけど、g++ではclassが予約語なせいかコンパイルが通らなかったので自前で定義。。。
 */
typedef struct {
	/**
	 * レシーバ（メッセージを受信するオブジェクト）
	 */
	id	receiver;
	
	/**
	 * スーパークラスのクラス情報
	 */
	Class superClass;
} _my_objc_super;

/**
 * スーパークラスのセレクタ（メソッド）を呼び出すときのobjc_msgSend
 * 
 * @param	super		スーパークラスインスタンス
 * @param	op			メソッド名（セレクタ）
 * @param	r2			メソッドの第1引数
 * @param	r3			メソッドの第2引数
 * @param	...			第3引数以降の可変長引数リスト
 */
extern "C"
void msg_debug_super( _my_objc_super *super, SEL op, unsigned r2, unsigned r3, ... ) {
	va_list arg;
	va_start( arg, r3 );
	ArgInfo argInfo = { 2, { r2, r3 }, adjustStdArgAddr( arg ) };
	msgTrace( super->receiver, super->superClass, op, argInfo );
	va_end( arg );
}

/**
 * 戻り値を受け取る かつ スーパー
 * 
 * @param	stretAddr	戻り値を受けるアドレス
 * @param	super		スーパークラスインスタンス
 * @param	op			メソッド名（セレクタ）
 * @param	r3			メソッドの第1引数
 * @param	...			第3引数以降の可変長引数リスト
 */
extern "C"
void msg_debug_super_stret( void * stretAddr, _my_objc_super *super, SEL op, unsigned r3, ... ) {
	va_list arg;
	va_start( arg, r3 );
	ArgInfo argInfo = { 1, { r3, 0 }, adjustStdArgAddr( arg ) };
	msgTrace( super->receiver, super->superClass, op, argInfo );
	va_end( arg );
}

/*
static void segvHandler( int sig ){
	signal( sig, SIG_IGN );
	throw "SIGSEGV";
	signal( SIGSEGV, segvHandler );
}
*/

extern "C"
void HookObjcFunctions( const char *appName ){

//	signal( SIGSEGV, segvHandler );
	sprintf( LogFileName, "/tmp/itracer_%s.log", appName );	

#if LOG_THREADING
	pthread_create( &Thread, NULL, ( void *(*)(void *) )logThread, NULL );
	pthread_detach( Thread );
#endif
	
#define FUNC(symbol, prototype)		MSHookFunction( (void *)symbol, (void *)replaced_##symbol, (void **)&old_##symbol );
#include "objc_funcs.h"
#undef FUNC
}

