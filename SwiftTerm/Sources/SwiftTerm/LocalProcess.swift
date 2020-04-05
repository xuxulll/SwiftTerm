//
//  LocalProcess.swift
//  
// This file contains the supporting infrastructure to run local processes that can be connected
// to a Termianl
//
//  Created by Miguel de Icaza on 4/5/20.
//

import Foundation


public protocol LocalProcessDelegate {
    /// This method is invoked on the delegate when the process has exited
    /// - Parameter source: the local process that terminated
    func processTerminated (_ source: LocalProcess)
    
    /// This method is invoked when data has been received from the local process that should be send to the terminal for processing.
    func dataReceived (slice: ArraySlice<UInt8>)

    /// This method should return the window size to report to the local process.
    func getWindowSize () -> winsize
}

/**
 * This class provides the capabilities to launch a local Unix process, and connect it to a `Terminal`
 * class or subclass.
 */
public class LocalProcess {
    /* Our buffer for reading data from the child process */
    var readBuffer: [UInt8] = Array.init (repeating: 0, count: 8192)
    
    /* The file descriptor used to communicate with the child process */
    var childfd: Int32 = -1
    
    /* The PID of our subprocess */
    var shellPid: pid_t = 0
    var debugIO = false
    
    /* number of sent requests */
    var sendCount = 0
    var total = 0

    var delegate: LocalProcessDelegate
    
    /**
     * Initializes the LocalProcess runner and communication with the host happens via the provided
     * `LocalProcessDelegate` instance.
     */
    public init (terminal: Terminal, delegate: LocalProcessDelegate)
    {
        self.delegate = delegate
    }
    
    /**
     * Sends the array slice to the local process using DispatchIO
     * - Parameter data: The range of bytes to send to the child process
     */
    public func send (data: ArraySlice<UInt8>)
    {
        guard running else {
            return
        }
        let copy = sendCount
        sendCount += 1
        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            if debugIO {
                print ("[SEND-\(copy)] Queuing data to client: \(data) ")
            }

            //DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.main, handler: childProcessWrite)
            DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.global(), handler:  { dd, errno in
                self.total += copy
                if self.debugIO {
                    print ("[SEND-\(copy)] completed bytes=\(self.total)")
                }
                if errno != 0 {
                    print ("Error writing data to the child")
                }
            })
        }

    }
    
    /* Used to generate the next file name counter */
    var logFileCounter = 0
    
    /* Total number of bytes read */
    var totalRead = 0
    func childProcessRead (data: DispatchData, errno: Int32)
    {
        if debugIO {
            totalRead += data.count
            print ("[READ] count=\(data.count) received from host total=\(totalRead)")
        }
        
        if data.count == 0 {
            childfd = -1
            running = false
            delegate.processTerminated (self)
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            if let dir = loggingDir {
                let path = dir + "/log-\(logFileCounter)"
                do {
                    let dataCopy = Data (ptr)
                    try dataCopy.write(to: URL.init(fileURLWithPath: path))
                    logFileCounter += 1
                } catch {
                    // Ignore write error
                    print ("Got error while logging data dump to \(path): \(error)")
                }
            }
        })
        delegate.dataReceived(slice: b[...])
        //print ("All data processed \(data.count)")
        DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
    }
    
    var running: Bool = false
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil)
     {
        if running {
            return
        }
        var size = delegate.getWindowSize ()
    
        var shellArgs = args
        shellArgs.insert(executable, at: 0)
        
        var env: [String]
        if environment == nil {
            env = Terminal.getEnvironmentVariables(termName: "xterm-color")
        } else {
            env = environment!
        }
        
        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: env, desiredWindowSize: &size) {
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
            DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
        }
    }
    
    var loggingDir: String? = nil
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     */
    public func setHostLogging (directory: String?)
    {
        loggingDir = directory
    }
}
