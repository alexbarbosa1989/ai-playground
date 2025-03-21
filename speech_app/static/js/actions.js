let mediaRecorder;
let audioChunks = [];

document.getElementById("recordButton").addEventListener("click", async function () {
    if (!mediaRecorder || mediaRecorder.state === "inactive") {
        startRecording();
    } else {
        stopRecording();
    }
});

document.getElementById("sendButton").addEventListener("click", sendTextMessage);

document.getElementById("userInput").addEventListener("keypress", function (event) {
    if (event.key === "Enter") {
        sendTextMessage();
    }
});

document.getElementById("attachButton").addEventListener("click", function () {
    document.getElementById("fileInput").click();
});

async function sendTextMessage() {
    let userMessage = document.getElementById("userInput").value.trim();
    if (!userMessage) return;

    document.getElementById("status").innerText = "Processing...";
    const response = await fetch("/process_text", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: userMessage })
    });

    const data = await response.json();
    updateChat(userMessage, data.response);
    document.getElementById("userInput").value = ""; // Clear input after sending
    document.getElementById("status").innerText = "";
}

function updateChat(userMessage, agentResponse) {
    document.getElementById("userText").innerText = userMessage;
    document.getElementById("agentResponse").innerText = agentResponse;
}

async function startRecording() {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    mediaRecorder = new MediaRecorder(stream);

    mediaRecorder.ondataavailable = event => {
        audioChunks.push(event.data);
    };

    mediaRecorder.onstop = async () => {
        const audioBlob = new Blob(audioChunks, { type: "audio/wav" });
        audioChunks = [];
        sendAudio(audioBlob);
    };

    mediaRecorder.start();
    document.getElementById("status").innerText = "🎙️";
    document.getElementById("recordButton").innerText = "⏹️";
    document.getElementById("recordButton").classList.add("listening");
}

function stopRecording() {
    mediaRecorder.stop();
    document.getElementById("status").innerText = "Processing...";
    document.getElementById("recordButton").innerText = "🎤";
    document.getElementById("recordButton").classList.remove("listening");
}

async function sendAudio(audioBlob) {
    const formData = new FormData();
    formData.append("audio", audioBlob);

    const response = await fetch("/process_audio", {
        method: "POST",
        body: formData
    });

    const data = await response.json();
    document.getElementById("userText").innerText = data.user;
    document.getElementById("agentResponse").innerText = data.response;
    document.getElementById("status").innerText = "Press the button and speak...";
}

document.getElementById("sendButton").addEventListener("click", async function () {
    let userMessage = document.getElementById("userInput").value;
    if (!userMessage.trim()) return;

    const response = await fetch("/process_text", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: userMessage })
    });

    const data = await response.json();
    updateChat(userMessage, data.response);
});

document.getElementById("speakButton").addEventListener("click", function () {
    let responseText = document.getElementById("agentResponse").innerText;
    if (responseText && responseText !== "---") {
        let speech = new SpeechSynthesisUtterance(responseText);
        speech.lang = "en-US"; // Adjust language if needed
        speech.rate = 1; // Speed (1 = normal)
        speech.volume = 1; // Max volume
        speech.pitch = 1; // Pitch level
        window.speechSynthesis.speak(speech);
    }
});

const userInput = document.getElementById("userInput");

userInput.addEventListener("input", () => {
    userInput.style.height = "auto"; // Reset the height to auto
    userInput.style.height = userInput.scrollHeight + "px"; // Set the height based on scrollHeight
});

document.getElementById("fileInput").addEventListener("change", function () {
    let file = this.files[0];
    if (!file) return;

    let formData = new FormData();
    formData.append("file", file);

    document.getElementById("status").innerText = "Uploading...";

    fetch("/process_file", {
        method: "POST",
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        updateChat(`📎 Uploaded: ${file.name}`, data.response);
        document.getElementById("status").innerText = "";
    })
    .catch(error => {
        console.error("File upload error:", error);
        document.getElementById("status").innerText = "Upload failed!";
    });
});

function updateChat(userMessage, agentResponse) {
    document.getElementById("userText").innerText = userMessage;
    document.getElementById("agentResponse").innerText = agentResponse;

    let responseContainer = document.getElementById("responseContainer");
    if (agentResponse && agentResponse !== "---") {
        responseContainer.style.display = "block";
    } else {
        responseContainer.style.display = "none";
    }
}