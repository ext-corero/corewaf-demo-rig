// corewaf-rig — Docker Desktop extension host helper.
//
// The extension UI cannot see the operator's home directory, so this tiny
// binary (shipped per OS inside the extension image) runs the rig-launcher
// container with the host's ~/.aws mounted and the docker socket attached:
//
//	corewaf-rig <aws-profile> <launcher-image> <verb> [args...]
//
// It is the exact `docker run` from the README, nothing more. For `up` it
// first refreshes the host's ECR login (12 h tokens) so the launcher image
// itself can be pulled. Output streams back to the UI unchanged.
package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
)

func home() string {
	if u, err := user.Current(); err == nil && u.HomeDir != "" {
		return u.HomeDir
	}
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return "."
}

func run(name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Stdout, c.Stderr, c.Stdin = os.Stdout, os.Stderr, nil
	return c.Run()
}

// ecrLogin: docker login to the launcher's registry using the AWS profile,
// via the aws-cli container (no host AWS CLI needed) — same as bootstrap.sh.
func ecrLogin(awsDir, profile, registry string) error {
	region := "us-east-1"
	if parts := strings.Split(registry, "."); len(parts) >= 4 && parts[1] == "dkr" {
		region = parts[3]
	}
	pw := exec.Command("docker", "run", "--rm", "-v", awsDir+":/root/.aws:ro", "-e", "AWS_PROFILE="+profile,
		"public.ecr.aws/aws-cli/aws-cli", "ecr", "get-login-password", "--region", region)
	var out, errb bytes.Buffer
	pw.Stdout, pw.Stderr = &out, &errb
	if err := pw.Run(); err != nil {
		return fmt.Errorf("ecr get-login-password (profile %s): %v\n%s", profile, err, errb.String())
	}
	login := exec.Command("docker", "login", "--username", "AWS", "--password-stdin", registry)
	login.Stdin = strings.NewReader(strings.TrimSpace(out.String()))
	login.Stdout, login.Stderr = os.Stdout, os.Stderr
	return login.Run()
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: corewaf-rig <aws-profile> <launcher-image> <verb> [args...]")
		os.Exit(2)
	}
	profile, image, verb, rest := os.Args[1], os.Args[2], os.Args[3], os.Args[4:]
	awsDir := filepath.Join(home(), ".aws")
	if _, err := os.Stat(awsDir); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %s not found — configure the pull user first: aws configure --profile %s\n", awsDir, profile)
		os.Exit(1)
	}
	registry := strings.SplitN(image, "/", 2)[0]
	if verb != "up" && verb != "pull" {
		// Best-effort refresh so a newly published launcher is picked up by every
		// verb, not only by `up`. An expired registry token just means we run the
		// cached image; `up` does the full login+pull.
		q := exec.Command("docker", "pull", "-q", image)
		q.Stdout, q.Stderr = nil, nil
		_ = q.Run()
	}
	if verb == "up" || verb == "pull" {
		fmt.Printf("── registry login (%s, profile %s) ──\n", registry, profile)
		if err := ecrLogin(awsDir, profile, registry); err != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", err)
			os.Exit(1)
		}
		fmt.Println("── pulling launcher ──")
		if err := run("docker", "pull", "-q", image); err != nil {
			os.Exit(1)
		}
		if verb == "pull" {
			return
		}
	}
	sock := "/var/run/docker.sock"
	if runtime.GOOS == "windows" {
		sock = "//var/run/docker.sock" // Docker Desktop maps this to the engine's socket
	}
	args := []string{"run", "--rm", "-v", sock + ":/var/run/docker.sock", "-v", awsDir + ":/root/.aws:ro",
		"-e", "AWS_PROFILE=" + profile, "-e", "TERM=dumb", image, verb}
	args = append(args, rest...)
	if err := run("docker", args...); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		os.Exit(1)
	}
}
