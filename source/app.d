// Proxy server for NNTP to add `markup=markdown` to any Content-Type header.
// Eventually, we might use a separate header to enable markdown, and just translate the header to Content-type.
// Thunderbird does not allow modifying content-type so this will do it for us.
//
// Inspired by this gist: https://gist.github.com/CyberShadow/ccb3813d5953e5e7f2c53fe43275f986
//
// At the moment, std.io is not asynchronous, so we use threads to handle all connections
// Any exceptions kill the thread or process
//
import std.io;
import std.io.driver : stdout;
import std.stdio : writeln, writefln; // for now

import iopipe.bufpipe;
import iopipe.textpipe;
import iopipe.valve;
import iopipe.refc;

import core.thread;

enum targetServer = "news.digitalmars.com";
enum targetPort = 119;
enum bindPort = 4119;
//enum bindAddr = IPv4Addr(127,0,0,1);
enum bindAddr = IPv4Addr(0,0,0,0);

__gshared bool running = true;

void releaseAll(Chain)(ref Chain ch)
{
    ch.release(ch.window.length);
}

class ClientThread : Thread
{
    RefCounted!(TCPServer.Client) incoming;
    RefCounted!TCP outgoing;
    this(RefCounted!(TCPServer.Client) client, RefCounted!TCP server)
    {
        super(&run);
        // save for putting into the pipe
        this.incoming = client;
        this.outgoing = server;
    }

    void run()
    {
        import std.ascii : isWhite, toUpper;
        import std.algorithm : startsWith;
        // setup the incoming iopipe
        auto input = incoming.bufd
            .outputPipe(File(stdout).refCounted)
            .assumeText
            .byLine;

        // create an outgoing iopipe
        auto output = bufd!char
            .push!(p => p.encodeText.outputPipe(outgoing), false);

        scope(exit) output.flush; // make sure any lingering data is flushed

        void writeOut(const(char)[] data)
        {
            while(data.length)
            {
                if(output.window.length == 0)
                    output.extend(0);
                size_t elems = data.length < output.window.length ? data.length : output.window.length;
                output.window[0 .. elems] = data[0 .. elems];
                output.release(elems);
                data = data[elems .. $];
            }
        }
outer:
        while(true)
        {
            // at the start of a message, look for the command.
            if(input.extend(0) == 0)
                // end of stream
                break;

            // got the start of a message.
            if(input.window.startsWith("POST") && isWhite(input.window[4]))
            {
                writeOut(input.window);
                input.releaseAll;
                // POST message, look for "\r\nContent-Type:" headers
                bool headersDone = false;
                while(!headersDone)
                {
                    if(input.extend(0) == 0)
                        break outer;
                    if(input.window.startsWith!((a, b) => toUpper(a) == b)("CONTENT-TYPE:"))
                    {
                        // output substitute
                        writeOut("Content-Type: markup=markdown;");
                        // write out the rest of the line
                        writeOut(input.window["Content-Type:".length .. $]);
                        // skip processing any other headers, we don't care about them.
                        headersDone = true;
                    }
                    else
                    {
                        writeOut(input.window);
                        // look for the end of headers
                        headersDone = input.window == "\r\n";
                    }
                    input.releaseAll;
                }
                if(input.extend(0) == 0)
                    break;

                // now, write out everything until we see the line .\r\n
                bool messageDone;
                while(!messageDone)
                {
                    writeOut(input.window);
                    // check for the termination sequence
                    if(input.window == ".\r\n")
                        messageDone = true;
                    input.releaseAll;
                }

                // make sure the output is flushed to the server, this is a full message
                output.flush;
            }
            else
            {
                // either part of another command or another command. Don't wait, just send the data immediately.
                writeOut(input.window);
                output.flush;
            }
        }

        writeOut(input.window);
        output.flush;
        writeln("End of client input from ", incoming.remoteAddr);
        // todo: close write end of outgoing 
    }
}

class ServerThread : Thread
{
    RefCounted!(TCPServer.Client) outgoing;
    RefCounted!TCP incoming;

    this(RefCounted!(TCPServer.Client) client, RefCounted!(TCP) server)
    {
        super(&run);
        this.incoming = server;
        this.outgoing = client;
    }

    void run()
    {
        // simple forward of all data.
        incoming.bufd.outputPipe(outgoing).process();
        writeln("End of server input for ", incoming.localAddr);
        // todo: close write end of outgoing socket
        //outgoing.close();
    }
}

void main()
{
    import core.sys.posix.signal;
    signal(SIGPIPE, SIG_IGN);
    import std.algorithm : partition;
    auto listener = TCP.server(bindAddr, bindPort);
    Thread[] children;
    while(true)
    {
        SocketAddr clientAddr;
        auto conn = listener.accept.refCounted;
        writeln("Accept connection from ", conn.remoteAddr);
        auto serverConn = TCP.client(targetServer, targetPort).refCounted;
        writeln("Connected to ", targetServer, " using local address ", serverConn.localAddr);
        children ~= new ClientThread(conn, serverConn);
        children[$-1].start();
        children ~= new ServerThread(conn, serverConn);
        children[$-1].start();

        // join any joinaable threads
        /*auto joinable = children.partition!(t => t.isRunning);
        if(joinable.length)
        {
            foreach(t; joinable)
                t.join;
            children = children[0 .. $-joinable.length];
            children.assumeSafeAppend;
        }*/
    }
}
