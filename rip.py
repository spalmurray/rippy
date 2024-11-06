import subprocess
import sys

MEDIA_DIR = "/mnt/data1/media"

def invalid_usage():
    print("Invalid usage. Examples:")
    print("rip.py movie [Movie filename] [optional: quality (e.g., 1080p, 4k)]")
    print("rip.py show [Show filename] [Season #] [Start Episode #] [End Episode #] [Min length (in minutes)] [Max length (in minutes)]")
    print("rip.py shuffle [Show filename] [path to episode mapping file]")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        invalid_usage()
        sys.exit()

    if sys.argv[1] == "movie" and len(sys.argv) < 3:
        invalid_usage()
        sys.exit()

    if sys.argv[1] == "show" and len(sys.argv) < 8:
        invalid_usage()
        sys.exit()

    if sys.argv[1] == "shuffle" and len(sys.argv) < 4:
        invalid_usage()
        sys.exit()

    if sys.argv[1] != "show" and sys.argv[1] != "movie" and sys.argv[1] != "shuffle":
        invalid_usage()
        sys.exit()

    type = sys.argv[1]
    name = sys.argv[2]

    if name.endswith(".mkv"):
        name = name[:-4]

    media_dir = f"{MEDIA_DIR}/{type if type != 'shuffle' else 'show'}s/{name}"
    
    if type == "shuffle":
        mapping_file = sys.argv[3]
        mapping = {}
        with open(mapping_file, 'r') as f:
            line = f.readline()
            while line:
                if line.startswith('Season '):
                    season = f"0{int(line[7:-2])}"[-2:]
                    mapping[season] = {}
                    line = f.readline()
                    while line and not line.startswith('Season '):
                        old, new = line.split(': ')
                        old = f"0{int(old)}"[-2:]
                        new = f"0{int(new)}"[-2:]
                        mapping[season][old] = new
                        line = f.readline()

        for season in mapping:
            for episode in mapping[season]:
                subprocess.run(["mv", f"{media_dir}/Season {season}/Episode S{season}E{episode}.mkv", f"{media_dir}/Season {season}/Episode S{season}E{episode}tmp.mkv"], capture_output=True)

            for episode in mapping[season]:
                subprocess.run(["mv", f"{media_dir}/Season {season}/Episode S{season}E{episode}tmp.mkv", f"{media_dir}/Season {season}/Episode S{season}E{mapping[season][episode]}.mkv"], capture_output=True)
                print("moved", "season", season, "episode", episode, "to", mapping[season][episode])

        sys.exit()

    subprocess.run(["mkdir", media_dir], capture_output=True)

    if type == "show":
        try:
            # Make sure season and episode are integers
            season = f"0{int(sys.argv[3])}"[-2:]
            first_episode = int(sys.argv[4])
            last_episode = int(sys.argv[5])
            min_length = int(sys.argv[6])
            max_length = int(sys.argv[7])

            media_dir = f"{media_dir}/Season {season}"

            subprocess.run(["mkdir", media_dir], capture_output=True)
        except:
            invalid_usage()
            sys.exit()


    print("\nScanning titles...")
    info = subprocess.run(["makemkvcon", "-r", "info", "disc:0"], capture_output=True).stdout.decode('utf-8').split('\n')

    titles = []

    i = 0
    while i in range(len(info)):
        line = info[i]
        if not line.startswith("TINFO"):
            i += 1
            continue

        # Parse the title metadata
        fields = line[6:].split(',', 3)
        title_id = fields[0]
        line_title_id = fields[0]
        line_type = fields[1]
        line_value = fields[3]
        title_name = '"Unknown"'
        title_runtime = ["0", "00", "00"]
        while line_title_id == title_id:
            if line_type == "2":
                title_name = line_value
            elif line_type == "9":
                title_runtime = line_value.strip('"').split(':')

            i += 1
            if i not in range(len(info)):
                break

            line = info[i]

            if not line.startswith("TINFO"):
                break

            line_fields = line[6:].split(',', 3)
            line_title_id = line_fields[0]
            line_type = line_fields[1]
            line_value = line_fields[3]

        title_runtime_minutes = int(title_runtime[0]) * 60 + int(title_runtime[1])
        if type == "show" and (title_runtime_minutes < min_length or title_runtime_minutes > max_length):
            continue
        titles.append((title_id, title_name, title_runtime[0], title_runtime[1], title_runtime[2]))

    # sort titles by runtime if it's a movie, we probably want just the longest one in that case.
    if type == "movie":
        titles.sort(reverse=True, key=lambda x: int(x[2]) * 3600 + int(x[3]) * 60 + int(x[4]))

    print("\nTitles:")
    for title in titles:
        print(f"Title {title[0]}: {title[1]} ({title[2]}:{title[3]}:{title[4]})")

    if type == "movie":
        title = input("\nWhich title number would you like to rip?\n")

        print(f"\nRipping title {title}...\n")

        subprocess.run(["mkdir", f"{media_dir}/tmp"], capture_output=True)
        subprocess.run(["makemkvcon", "mkv", "disc:0", title, f"{media_dir}/tmp"], capture_output=True)

        filename = f"{name}"
        quality = None
        if len(sys.argv) > 3:
            quality = sys.argv[3]

        tmp_contents = subprocess.run(["ls", f"{media_dir}/tmp"], capture_output=True).stdout.decode('utf-8').split('\n')[:-1]

        for file in tmp_contents:
            ext = file.split('.')[-1]
            subprocess.run(["mv", f"{media_dir}/tmp/{file}", f"{media_dir}/{filename}{' - ' + quality if quality else ''}.{ext}"], capture_output=True)

        subprocess.run(["rm", "-r", f"{media_dir}/tmp"], capture_output=True)

        print(f"Done!\nOutput: {media_dir}/{filename}.mkv")
        sys.exit()

    # Show
    start_title = int(input(f"\nWhich title number is episode {first_episode}?\n"))
    start_index = -1
    for i in range(len(titles)):
        if int(titles[i][0]) == start_title:
            start_index = i
            break

    num_episodes = last_episode - first_episode + 1
    season_str = f"0{int(sys.argv[3])}"[-2:]

    for i in range(num_episodes):
        title = titles[start_index + i][0]
        episode = first_episode + i

        print(f"\nRipping title {title} as episode {episode}...")
    
        subprocess.run(["mkdir", f"{media_dir}/tmp"], capture_output=True)
        subprocess.run(["makemkvcon", "mkv", "disc:0", title, f"{media_dir}/tmp"], capture_output=True)

        episode_str = f"0{episode}"[-2:]
        filename = f"Episode S{season_str}E{episode_str}"

        tmp_contents = subprocess.run(["ls", f"{media_dir}/tmp"], capture_output=True).stdout.decode('utf-8').split('\n')[:-1]

        for file in tmp_contents:
            ext = file.split('.')[-1]
            subprocess.run(["mv", f"{media_dir}/tmp/{file}", f"{media_dir}/{filename}.{ext}"], capture_output=True)

        subprocess.run(["rm", "-r", f"{media_dir}/tmp"], capture_output=True)

        print(f"Done!\nOutput: {media_dir}/{filename}.mkv")

    print(f"\nDone ripping episodes {first_episode} through {last_episode}")
    sys.exit()
