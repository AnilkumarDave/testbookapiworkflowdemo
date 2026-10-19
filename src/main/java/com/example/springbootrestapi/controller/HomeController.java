package com.example.springbootrestapi.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
/**controller**/
@RestController
public class HomeController {

    @GetMapping("/")
    public String home() {
        //verify 
        return "Spring Boot REST API is running. Use /api/books";
    }
}
