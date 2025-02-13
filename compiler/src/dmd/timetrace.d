/**
Compilation time tracing, -ftime-trace.

The time trace profile is output in the Chrome Trace Event Format, described
here: https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview

This file is originally from LDC (the LLVM D compiler).

Copyright: Copyright (C) 1999-2022 by The D Language Foundation, All Rights Reserved
Authors:   Johan Engelen, Max Haughton, Dennis Korpel
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/common/timetrace.d, common/_timetrace.d)
Documentation: https://dlang.org/phobos/dmd_common_timetrace.html
Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/common/timetrace.d
*/
module dmd.timetrace;

import dmd.location;
import dmd.dsymbol;
import dmd.expression;
import dmd.root.array;
import dmd.common.outbuffer;
import dmd.root.string : toDString;

// Thread local profiler instance (multithread currently not supported because compiler is single-threaded)
TimeTraceProfiler* timeTraceProfiler = null;

/**
 * Initialize time tracing functionality.
 *
 * Must be called before any other calls to timeTrace functions.
 *
 * Params:
 *   timeGranularityUs = minimum event size in microseconds
 *   processName = name of this executable
 */
extern (C++)
void initializeTimeTrace(uint timeGranularityUs, const(char)* processName)
{
    assert(timeTraceProfiler is null, "Double initialization of timeTraceProfiler");
    timeTraceProfiler = new TimeTraceProfiler(timeGranularityUs, processName);
}

/**
 * Cleanup for time tracing functionality.
 *
 * After this, no more calls to timeTrace functions can be made.
 */
extern (C++)
void deinitializeTimeTrace()
{
    if (timeTraceProfilerEnabled())
    {
        object.destroy(timeTraceProfiler);
        timeTraceProfiler = null;
    }
}

/**
 * Returns: Whether time tracing is enabled.
 */
pragma(inline, true)
extern (C++)
bool timeTraceProfilerEnabled()
{
    version (LDC)
    {
        import ldc.intrinsics : llvm_expect;

        return llvm_expect(timeTraceProfiler !is null, false);
    }
    else
    {
        return timeTraceProfiler !is null;
    }
}

/**
 * Write all time tracing results so far to JSON, in the Chrome Trace Event Format.
 * Params:
 *   buf = output buffer to write JSON into
 */
extern (C++)
void writeTimeTraceProfile(OutBuffer* buf)
{
    timeTraceProfiler.writeToBuffer(*buf);
}

/**
 * Start a new time trace event (C++ interface using upfront C-strings instead of lazy delegates)
 *
 * Params:
 *   name_ptr = event name, visible in high level profile view
 *   detail_ptr = further details, visible when this event is selected
 *   loc = source location corresponding to this event
 */
extern (C++)
void timeTraceBeginEvent(scope const(char)* name_ptr, scope const(char)* detail_ptr, Loc loc)
{
    import dmd.root.rmem : xarraydup;

    assert(timeTraceProfiler);

    timeTraceProfiler.beginScope(
        xarraydup(name_ptr.toDString()),
        xarraydup(detail_ptr.toDString()), loc
    );
}

/**
 * Start a new time trace event
 *
 * Details of the event will be passed as delegates to `timeTraceEndEvent` so
 * they're only generated when the event is actually written.
 *
 * Params:
 *   eventType = what compilation stage the event belongs to
 *      (redundant with the eventType of `timeTraceEndEvent` but used by GDC)
 */
extern (C++)
void timeTraceBeginEvent(TimeTraceEventType eventType)
{
    if (timeTraceProfilerEnabled)
        timeTraceProfiler.beginScope(null, null, Loc.initial);
}

/**
 * End a time tracing event, optionally updating the event name and details
 * with a delegate. Delegates are used to prevent spending time on string
 * generation when an event is too small to be generated anyway.
 *
 * Params:
 *   eventType = what compilation stage the event belongs to
 *   sym = Dsymbol which was analyzed, used to generate 'name' and 'detail'
 *   e = Expression which was analyzed, used to generate 'name' and 'detail'
 *   detail = custom lazy string for 'detail' of event
 */
extern (C++)
void timeTraceEndEvent(TimeTraceEventType eventType)
{
    if (timeTraceProfilerEnabled)
        timeTraceProfiler.endScope(eventType, null, null, Loc.initial);
}

/// ditto
void timeTraceEndEvent(TimeTraceEventType eventType, Dsymbol sym, scope const(char)[] delegate() detail = null)
{
    if (timeTraceProfilerEnabled)
    {
        timeTraceProfiler.endScope(
            eventType,
            () => sym.isImport() ? sym.toPrettyChars().toDString() : sym.toChars().toDString(),
            detail ? detail : () => sym.toPrettyChars().toDString(),
            sym.loc
        );
    }
}

/// ditto
extern (C++)
void timeTraceEndEvent(TimeTraceEventType eventType, Expression e)
{
    if (timeTraceProfilerEnabled)
        timeTraceProfiler.endScope(eventType, () => e.toChars().toDString(),
            () => e.toChars().toDString(), e.loc);
}

/// Identifies which compilation stage the event is associated to
enum TimeTraceEventType
{
    generic,
    parseGeneral,
    parse,
    semaGeneral,
    sema1Import,
    sema1Module,
    sema2,
    sema3,
    ctfe,
    ctfeCall,
    codegenGlobal,
    codegenModule,
    codegenFunction,
    link,
}

/// Names corresponding to `TimeTraceEventType`
private immutable string[] eventPrefixes = [
    "",
    "Parsing",
    "Parse: Module ",
    "Semantic analysis",
    "Import ",
    "Sema1: Module ",
    "Sema2: ",
    "Sema3: ",
    "Ctfe: ",
    "Ctfe: call ",
    "Code generation",
    "Codegen: module ",
    "Codegen: function ",
    "Linking",
];

/// Integer type holding timer value
private alias TimeTicks = long;

/// A measurement at a point in time. Used for reporting RAM usage.
private struct CounterEvent
{
    size_t memoryInUse;
    ulong allocatedMemory;
    size_t numberOfGCCollections;
    TimeTicks timepoint;
}

/// An event with a start and end time
private struct DurationEvent
{
    const(char)[] name = null;
    const(char)[] details = null;
    Loc loc;
    TimeTicks timeBegin;
    TimeTicks timeDuration;
}


private struct TimeTraceProfiler
{
    import core.time;

    TimeTicks timeGranularity; /// Minimum duration event size
    const(char)[] processName; /// Name of the executable being profiled
    /// String to identify process and thread (in this case, there's just a single process and thread)
    const(char)[] pidtidString = `"pid":101,"tid":101`;

    TimeTicks beginningOfTime; /// Timer value at start of profiling
    Array!CounterEvent counterEvents; /// All counter event so far
    Array!DurationEvent durationEvents; /// All duration events so far
    Array!DurationEvent durationStack; /// Gets pushed to / popped from when an event begins/ends.

    @disable this();
    @disable this(this);

    this(uint timeGranularity_usecs, const(char)* processName)
    {
        this.timeGranularity = timeGranularity_usecs * (MonoTime.ticksPerSecond() / 1_000_000);
        this.processName = processName.toDString();
        this.beginningOfTime = getTimeTicks();
    }

    private TimeTicks getTimeTicks()
    {
        return MonoTime.currTime().ticks();
    }

    void beginScope(const(char)[] name, const(char)[] details, Loc loc)
    {
        DurationEvent event;
        event.name = name;
        event.details = details;
        event.loc = loc;
        event.timeBegin = getTimeTicks();
        durationStack.push(event);
    }

    /// Takes ownership of the string returned by `name` and `details`.
    void endScope(TimeTraceEventType eventType, scope const(char)[] delegate() name, scope const(char)[] delegate() details, Loc loc)
    {
        TimeTicks timeEnd = getTimeTicks();

        DurationEvent event = durationStack.pop();
        event.timeDuration = timeEnd - event.timeBegin;
        if (event.timeDuration >= timeGranularity)
        {
            // Event passes the logging threshold
            if (name)
                event.name = eventPrefixes[eventType] ~ name();
            else if (!event.name)
                event.name = eventPrefixes[eventType];

            if (details)
                event.details = details();
            if (loc != Loc.initial)
                event.loc = loc;
            event.timeBegin -= beginningOfTime;
            durationEvents.push(event);
            counterEvents.push(generateCounterEvent(timeEnd - beginningOfTime));
        }
    }

    private CounterEvent generateCounterEvent(TimeTicks timepoint)
    {
        static import dmd.root.rmem;

        CounterEvent counters;
        if (dmd.root.rmem.mem.isGCEnabled)
        {
            static if (__VERSION__ >= 2085)
            {
                import core.memory : GC;

                auto stats = GC.stats();
                auto profileStats = GC.profileStats();

                counters.allocatedMemory = stats.usedSize + stats.freeSize;
                counters.memoryInUse = stats.usedSize;
                counters.numberOfGCCollections = profileStats.numCollections;
            }
        }
        else
        {
            counters.allocatedMemory = dmd.root.rmem.heapTotal;
            counters.memoryInUse = dmd.root.rmem.heapTotal - dmd.root.rmem.heapleft;
        }
        counters.timepoint = timepoint;
        return counters;
    }

    void writeToBuffer(ref OutBuffer buf)
    {
        // Time is to be output in microseconds
        long timescale = MonoTime.ticksPerSecond() / 1_000_000;

        buf.write("{\n\"beginningOfTime\":");
        buf.print(beginningOfTime / timescale);
        buf.write(",\n\"traceEvents\": [\n");
        writeMetadataEvents(buf);
        writeCounterEvents(buf);
        writeDurationEvents(buf);
        // Remove the trailing comma (and newline!) to obtain valid JSON.
        if (buf[buf.length() - 2] == ',')
        {
            buf.setsize(buf.length() - 2);
            buf.writeByte('\n');
        }
        buf.write("]\n}\n");
    }

    private void writeMetadataEvents(ref OutBuffer buf)
    {
        // {"ph":"M","ts":0,"args":{"name":"bin/ldc2"},"name":"thread_name","pid":0,"tid":0},

        buf.write(`{"ph":"M","ts":0,"args":{"name":"`);
        buf.writeEscapeJSONString(processName);
        buf.write(`"},"name":"process_name",`);
        buf.write(pidtidString);
        buf.write("},\n");
        buf.write(`{"ph":"M","ts":0,"args":{"name":"`);
        buf.writeEscapeJSONString(processName);
        buf.write(`"},"cat":"","name":"thread_name",`);
        buf.write(pidtidString);
        buf.write("},\n");
    }

    private void writeCounterEvents(ref OutBuffer buf)
    {
        // {"ph":"C","name":"ctr","ts":111,"args": {"Allocated_Memory_bytes":  0, "hello":  0}},

        // Time is to be output in microseconds
        long timescale = MonoTime.ticksPerSecond() / 1_000_000;

        foreach (const ref event; counterEvents)
        {
            buf.write(`{"ph":"C","name":"ctr","ts":`);
            buf.print(event.timepoint / timescale);
            buf.write(`,"args": {"memoryInUse_bytes":`);
            buf.print(event.memoryInUse);
            buf.write(`,"allocatedMemory_bytes":`);
            buf.print(event.allocatedMemory);
            buf.write(`,"GC collections":`);
            buf.print(event.numberOfGCCollections);
            buf.write("},");
            buf.write(pidtidString);
            buf.write("},\n");
        }
    }

    private void writeDurationEvents(ref OutBuffer buf)
    {
        // {"ph":"X","name": "Sema1: somename","ts":111,"dur":222,"loc":"filename.d:123","args": {"detail": "something", "loc":"filename.d:123"},"pid":0,"tid":0}

        void writeLocation(Loc loc)
        {
            SourceLoc sl = SourceLoc(loc);
            if (sl.filename.length > 0)
            {
                writeEscapeJSONString(buf, sl.filename);
                if (sl.line)
                {
                    buf.writeByte(':');
                    buf.print(sl.line);
                }
            }
            else
            {
                buf.write(`<no file>`);
            }
        }

        // Time is to be output in microseconds
        long timescale = MonoTime.ticksPerSecond() / 1_000_000;

        foreach (event; durationEvents)
        {
            buf.write(`{"ph":"X","name": "`);
            writeEscapeJSONString(buf, event.name);
            buf.write(`","ts":`);
            buf.print(event.timeBegin / timescale);
            buf.write(`,"dur":`);
            buf.print(event.timeDuration / timescale);
            buf.write(`,"loc":"`);
            writeLocation(event.loc);
            buf.write(`","args":{"detail": "`);
            writeEscapeJSONString(buf, event.details);
            // Also output loc data in the "args" field so it shows in trace viewers that do not support the "loc" variable
            buf.write(`","loc":"`);
            writeLocation(event.loc);
            buf.write(`"},`);
            buf.write(pidtidString);
            buf.write("},\n");
        }
    }
}

/**
 * Escape special characters (such as quotes and whitespaces) for a JSON string literal
 * Params:
 *   buf = buffer to write to
 *   str = string to escape and write as string literal
 */
private void writeEscapeJSONString(ref OutBuffer buf, const(char[]) str)
{
    foreach (char c; str)
    {
        switch (c)
        {
        case '\n':
            buf.writestring("\\n");
            break;
        case '\r':
            buf.writestring("\\r");
            break;
        case '\t':
            buf.writestring("\\t");
            break;
        case '\"':
            buf.writestring("\\\"");
            break;
        case '\\':
            buf.writestring("\\\\");
            break;
        case '\b':
            buf.writestring("\\b");
            break;
        case '\f':
            buf.writestring("\\f");
            break;
        default:
            if (c < 0x20)
                buf.printf("\\u%04x", c);
            else
            {
                // Note that UTF-8 chars pass through here just fine
                buf.writeByte(c);
            }
            break;
        }
    }
}
